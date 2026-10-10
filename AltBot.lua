-- ============================================================
-- AltBot.lua — Bag manager for mod-playerbots.
--
-- SECOND major redesign (per explicit user direction after a context-limit
-- pause: "придумал новый подход, нет больше никаких старт и стоп, нет
-- больше никаких игроков фармеров и тренеров"). The Farmer/Trainer-name +
-- Start/Stop model is GONE. New model:
--
-- ONE textarea, names separated by SPACES (not lines), case-insensitive.
-- The textarea is persisted/redisplayed EXACTLY as typed (no whitespace
-- collapsing, no comment stripping — per explicit user direction, Save
-- must not alter what's shown). Whitespace-collapsing and comment-
-- stripping (both "-token" and "--trailing comment") only happen when
-- PARSING it into botNames below, a separate step from what gets saved for
-- redisplay. Tokens are filtered/classified into botNames on every Save:
--   - A token matching UnitName("player") (case-insensitive) is the user
--     themselves — filtered out, never treated as a bot.
--   - A token starting with "-" is a comment — filtered out entirely.
--   - A token matching a class name (English OR Russian, with aliases —
--     see CLASS_NAME_ALIASES below, e.g. "dk"/"дк"/"deathknight" all mean
--     Death Knight; the two-word "рыцарь смерти" does NOT match, since it
--     can't be a single space-separated token) is NOT a bot name — it's a
--     standing wild-class quota: N occurrences of a class token means "N
--     wild bots of this class should be in the raid", re-checked on every
--     sync (recomputed from the saved roster text into NS.currentClassCounts
--     every time, never persisted on its own — see BuildRosterFromNames'
--     own doc comment — missing wilds get topped up via ".playerbots bot
--     addclass", excess wilds of that class get kicked).
--     Independent of named bots: a named bot's own class never counts
--     against a class quota, even if they match.
--   - Everything else is a tracked bot name, capped at 39 after filtering.
-- No account/discovery concept, no ConvertToRaid precondition-juggling
-- tied to a "start" action — grouping (where needed) just happens as part
-- of whichever mode is active.
--
-- THIRD major redesign: the textarea's Save button and the pet-style
-- action bar (right-click the minimap icon) replaced the old inline mode/
-- reaction/lifecycle buttons entirely — see the action bar's own big
-- comment block further down for the bar itself. What follows here is
-- about the mode system underneath it, which the bar just drives.
--
-- 3 modes, exactly one active at a time, stored in AltBot_SavedVars.mode:
-- Квест (Quest) / Фарм (Farm) / Solo. No mode is active until the user
-- first clicks Summon or Free Roam — a fresh install/character has
-- AltBot_SavedVars.mode == nil, and AltBot is fully inert (ApplyMode
-- no-ops on a nil mode — see its fresh-install guard). Filling the
-- textarea and clicking Summon/Free Roam is what starts everything: it
-- saves the roster AND sets the mode in the same action, which is when
-- grouping/strategy first apply.
--
-- Grouping (".playerbots bot add" for any tracked name missing from the
-- world/group, forming a party and converting to a raid once it qualifies —
-- see "Farm mode grouping" section, despite the name it now runs for every
-- non-Solo mode) happens the same way regardless of mode. The mode only
-- decides what happens to bots once grouped, and how bag space is handled:
--
-- ── Квест (Quest) mode ──
-- Bots keep whatever strategy they already have — AltBot never sends
-- "reset botAI", never changes nc/co strategy, never summons for unloading.
-- It only polls "stats" to watch bag space, and when ANY bot hits 0 free
-- slots, whispers "s *" (sell everything the vendor buys) to every tracked
-- bot individually — no group-chat broadcast, every automated command in
-- this file is a per-bot whisper (SendBotCommand), not raid/party chat.
--
-- ── Фарм (Farm) mode ──
-- This is the full cycle from the previous design: after grouping, poll
-- "stats", and on bagFree == 0 run reset botAI -> summon -> s * -> restore
-- strategy, one bot at a time. See the "Farm mode grouping" and "Farm mode
-- unload chain" sections below — largely unchanged from the prior design,
-- just no longer gated on a saved "farmer name".
--
-- ── Solo (NS.MODE_SOLO) ──
-- Set by DisbandRoster (the action bar's Disband button), not by a
-- mode-row button of its own. The roster's "everyone's put away" state:
-- ApplyMode is an explicit no-op while Solo (see its own early-return),
-- and the whole ticker skips its body too (see the main ticker below) —
-- nothing runs in the background for a despawned roster. A real,
-- persisted mode (not a side flag), so it survives a disconnect/reload for
-- free, same as Quest/Farm. Resuming happens only via an explicit Summon/
-- Free Roam click (or Save, if one of those is already the saved mode).
--
-- There's no Учёба/Study mode any more — replaced by an always-on (any
-- non-Solo mode) TRAINER_UPDATE watcher near TrainBots that whispers
-- "trainer" whenever the master actually opens a real trainer's window,
-- rather than a dedicated mode/button for it.
--
-- mod-playerbots gives no reliable chat confirmation for reset/summon/sell,
-- so step timing (Farm mode) uses one fixed delay between steps rather than
-- waiting for a reply — same tradeoff CleanBot makes for "reset botAI".
-- ============================================================

local ADDON_NAME = ...
local NS = {}

-- ============================================================
-- Config (tunable)
-- ============================================================
NS.POLL_INTERVAL    = 30    -- seconds between "stats" polls per tracked bot
NS.TRAINER_TARGET_DEBOUNCE = 3.0  -- min seconds between "trainer" passes triggered by TRAINER_UPDATE (see the watcher near TrainBots)
NS.REVIVE_INTERVAL  = 5.0   -- seconds between dead-bot checks (all modes) — see NS.CheckReviveBots
NS.STEP_DELAY       = 2.0   -- seconds between each Farm-mode unload-chain step
NS.DISCOVER_SETTLE  = 1.5   -- seconds the group must hold steady before scanning it (Farm mode)
NS.DISCOVER_TIMEOUT = 15.0  -- hard cap on waiting for the group to settle (Farm mode)
NS.RESTORE_STRATEGY = "nc +new rpg,-follow"
NS.STATS_TIMEOUT    = 5.0   -- give up on a lost/unanswered "stats" reply after this long
NS.MAX_BOTS         = 39    -- hard cap on filtered bot names from the textarea
NS.STRAY_GROUP_RESET_DELAY = 3.0  -- seconds to wait after whispering "leave" to the roster before re-adding (see ResetStrayGroups)

-- Chat output categories (Settings window -> "Chat output"): checked = shown,
-- unchecked = hidden from the chat window (display only, the addon still sees
-- everything). `show` is the default until the user toggles it. Order here is
-- the order of the checkboxes.
-- Only stats and rpg status have a checkbox for now (per explicit user
-- direction: "галки stats и rpg пока"); every other category the filters
-- below classify ("cmd", "reply", "system", "addon", "debug") isn't listed
-- here and is therefore always shown.
NS.CHAT_CATEGORIES = {
    -- One checkbox per area, so that one thing can be watched without the rest (per explicit user
    -- direction). Everything the addon prints that fits no area is "init"; only the supply ALARMS
    -- (NS.SystemShout) are shown regardless of the checkboxes.
    { key = "init",       label = "chat init",       show = false },   -- load, group forming, mode switches, trainer, failures, everything unclassified
    { key = "stats",      label = "chat stats",      show = false },   -- the board: "stats" polling
    { key = "farm",       label = "chat farm",       show = false },   -- Farm mode: rpg status, unload (summon/sell), revive, parking, tracking
    { key = "inventory",  label = "chat inventory",  show = false },   -- the bags window: items, trade/sell/equip/destroy of one item
    { key = "armory",     label = "chat armory",     show = false },   -- the armory window: who + the slot queries
    { key = "strategies", label = "chat strategies", show = false },   -- the strategy window: co/nc/ll queries and changes, "[Strategy] caught"
    { key = "questlog",   label = "chat questlog",   show = false },   -- the quest windows: quests all, drop
    { key = "spellbook",  label = "chat spellbook",  show = false },   -- the spellbook window: spells, cast
}

--- Whether chat category `key` (see NS.CHAT_CATEGORIES) is currently shown;
--- categories without a checkbox are always shown.
NS.ChatShown = function(key)
    local saved = AltBot_SavedVars and AltBot_SavedVars.chatShow
    if saved and saved[key] ~= nil then return saved[key] end
    for _, c in ipairs(NS.CHAT_CATEGORIES) do
        if c.key == key then return c.show end
    end
    return true
end

-- ConvertToRaid requires the leader (master) AND at least one other party
-- member to be level >= 10 — calling it before a qualifying member has
-- joined the party fails silently server-side (confirmed by the user, not
-- assumed). Farm mode only.
NS.RAID_CONVERT_MIN_LEVEL = 10

-- The 3 modes, radio-button style (exactly one active once chosen).
-- Персистится в AltBot_SavedVars.mode; nil until the user's first click on
-- a mode button (see the fresh-install flow in the file header above) — no
-- auto-selected default mode. MODE_SOLO is the 4th one: DisbandRoster sets
-- it directly (not via a mode-row button — see the action bar's Disband),
-- and ApplyMode treats it as an explicit no-op mode (bots despawned, stay
-- despawned) rather than "no mode configured yet" (nil) — see ApplyMode's
-- own early-return for the difference. There's no more Study mode/button;
-- see the NPC-trainer-target watcher further down for what replaced it.
NS.MODE_QUEST = "quest"
NS.MODE_FARM  = "farm"
NS.MODE_SOLO  = "solo"

-- The 3 mutually exclusive combat reactions, mirroring a real hunter pet's
-- Aggressive/Defensive/Passive (Blizzard's own name for the neutral middle
-- state is "Defensive", not "Default" — see the action bar's reaction row).
-- Persisted in AltBot_SavedVars.reaction; nil reads the same as Defensive
-- (see NS.EffectiveReaction) so a fresh install needs no explicit choice.
NS.REACTION_AGGRESSIVE = "aggressive"
NS.REACTION_DEFENSIVE  = "defensive"
NS.REACTION_PASSIVE    = "passive"

-- Follow/Stay, mutually exclusive like the reaction row above. Persisted in
-- AltBot_SavedVars.movement; nil reads as Follow (see NS.EffectiveMovement)
-- since that's the group's actual default behavior.
NS.MOVEMENT_FOLLOW = "follow"
NS.MOVEMENT_STAY   = "stay"

--- Returns (creating if needed) THIS character's own sub-table within the
--- account-wide AltBot_SavedVars. Reaction/movement and UI positions
--- (panelPoint, actionBarPoint, minimapAngle, panelShown, actionBarShown)
--- live here — personal to whichever character is playing right now, not
--- shared across the account (per explicit user direction). Purely cosmetic
--- preferences, unlike the fields below — none of these affect what the
--- addon actually DOES, only how its own windows look for this one
--- character.
---
--- botNames, rosterText, classCounts, AND mode are all plain top-level
--- AltBot_SavedVars fields instead, NOT in here — per explicit user
--- direction ("ростер должен быть один на аккаунт, а не у каждого чара
--- свой" / "режим моды должен быть один для аккаунта, какой был у
--- предыдущего мастера, такой должен быть у любого другого нового, пока
--- какой-то мастер не поменяет"): it's what lets the SAME physical group of
--- characters keep rotating who's "master" and who's "a bot" as you switch
--- between them (see the login handler's lastMasterName rotation), with
--- both the roster AND its lifecycle state (Quest/Farm/Solo) following
--- along. Both rosterText/classCounts and mode used to live here too (a bug,
--- not a deliberate split) — rosterText/classCounts being per-character left
--- a freshly-switched-to master's Roster textarea showing empty even though
--- the real botNames/group still had the whole roster (and Save from that
--- blank textarea would have silently wiped botNames/classCounts down to
--- empty for the whole account); mode being per-character meant a Disband
--- done under one master was invisible to every other master character —
--- logging into a DIFFERENT character after a Disband showed the stats
--- board full of stale columns instead of the empty Solo board the account
--- was actually left in (both confirmed by the user in-game).
NS.CharVars = function()
    AltBot_SavedVars = AltBot_SavedVars or {}
    AltBot_SavedVars.chars = AltBot_SavedVars.chars or {}
    local key = UnitName("player") or ""
    AltBot_SavedVars.chars[key] = AltBot_SavedVars.chars[key] or {}
    return AltBot_SavedVars.chars[key]
end

-- NS.EffectiveMode is defined further below, right after ParseRosterText
-- (which it calls) — see that definition for the full doc comment.

-- ============================================================
-- Class name recognition — English AND Russian, with common short aliases,
-- for the textarea's class-token detection (see file header). Keys are
-- lowercased tokens as typed; values are the ".playerbots bot addclass"
-- argument (the class's normal English lowercase name, per mod-playerbots
-- convention — mirrors the tokens CleanBot's Recruiter.lua sends).
-- ============================================================
NS.CLASS_NAME_ALIASES = {
    -- Warrior / Воин
    ["warrior"] = "warrior", ["воин"] = "warrior",
    -- Paladin / Паладин
    ["paladin"] = "paladin", ["паладин"] = "paladin",
    -- Hunter / Охотник
    ["hunter"] = "hunter", ["охотник"] = "hunter",
    -- Rogue / Разбойник
    ["rogue"] = "rogue", ["разбойник"] = "rogue",
    -- Priest / Жрец
    ["priest"] = "priest", ["жрец"] = "priest",
    -- Death Knight: "рыцарь смерти" is two words and can't match as a single
    -- space-separated token (per user correction — "тут пробел и лишнее
    -- имя, только /dk/дк"), so only the single-token forms are recognized.
    ["deathknight"] = "deathknight", ["dk"] = "deathknight", ["дк"] = "deathknight",
    -- Shaman / Шаман
    ["shaman"] = "shaman", ["шаман"] = "shaman",
    -- Mage / Маг
    ["mage"] = "mage", ["маг"] = "mage",
    -- Warlock / Чернокнижник
    ["warlock"] = "warlock", ["чернокнижник"] = "warlock",
    -- Druid / Друид
    ["druid"] = "druid", ["друид"] = "druid",
}

-- ============================================================
-- State
-- ============================================================
-- bots[nameKey] = {
--   name          = "Botname",     -- display name (whisper target)
--   class         = "WARRIOR" etc, -- from UnitClass while grouped
--   level         = number|nil,
--   bagFree       = number|nil,
--   bagTotal      = number|nil,
--   money         = { gold=, silver=, copper= } | nil,
--   xpPercent     = number|nil,    -- current level's XP percent, 0-100
--   xpHourBase    = number|nil,    -- xpPercent snapshot at the top of the current hour
--                                   -- (or 0, right after a mid-hour level-up)
--   xpHourStamp   = number|nil,    -- hour index (floor(time/3600)) the base belongs to
--   xpHourCarry   = number|nil,    -- % banked from level(s) finished earlier this hour
--   awaitingStats = boolean,       -- a "stats" whisper is in flight
--   statsTimer    = number,
--   step          = "idle"|"queued"|"vendor",  -- Farm mode bag-full chain only (see StartNextInQueue)
--   stepTimer     = number,
--   awaitingRpgStatus = boolean,   -- a "rpg status" whisper is in flight (Farm mode only)
--   rpgStatusTimer    = number,
--   wanderRandomStreak    = number|nil,  -- consecutive WANDER_RANDOM polls seen so far this backoff window
--   wanderRandomThreshold = number|nil,  -- how many WANDER_RANDOM polls to let through before retrying
--                                         -- "go grind" — starts at 2, grows by 2 each time "go grind"
--                                         -- comes back with no position, resets on a successful GO_GRIND
--   farmHeld      = boolean|nil,   -- Farm mode only: user clicked this bot's top (XP-gain) board row to pull
--                                   -- it to the master and park it there (reset botAI, no rpg status
--                                   -- polling/commands) until clicked again; cleared on any mode change
-- }
NS.bots = {}
NS.rosterOrder = {}   -- nameKey list in a stable, typed-in order (drives panel column order)

NS.queue  = {}   -- FIFO of nameKeys waiting to start the Farm-mode camp/vendor chain
NS.active = nil  -- nameKey currently running the Farm-mode camp/vendor chain, or nil

--- Prints an AltBot line to the chat if its category checkbox is on (default category "init").
local function Print(msg, category)
    if not NS.ChatShown(category or "init") then return end
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffAltBot|r: " .. msg)
end

-- ============================================================
-- One-shot delayed call (no C_Timer in 3.3.5 client Lua) — a disposable
-- OnUpdate frame that fires fn once after `delay` seconds, then discards
-- itself. Mirrors CleanBot's CB_After.
-- ============================================================
--- Strips WoW chat escape sequences (colors, textures, hyperlinks) from `text`.
NS.CleanEscapes = function(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("|T.-|t", ""):gsub("|H.-|h", ""):gsub("|h", "")
    return text
end

--- Shift-click on a link target (a bag item, a spell): the link goes into the chat edit box that is
--- open; with none open, a chat box is opened with the link in it - and the click's own action (trade,
--- sell, cast, macro) is NOT performed, per explicit user direction.
NS.InsertLinkIntoChat = function(link)
    if not link then return end
    if not ChatEdit_InsertLink(link) then ChatFrame_OpenChat(link) end
end

-- One shared frame runs every delayed call. (NS.After used to create a new Frame per call; WoW never
-- frees frames, so every poll cycle / retry / chain step leaked one - the addon ate the client's
-- memory.) Due calls run in due-time order; a call may schedule more.
NS.timers = {}
NS.timerClock = 0
NS.timerSeq = 0
NS.timerFrame = CreateFrame("Frame")
NS.timerFrame:SetScript("OnUpdate", function(self, dt)
    NS.timerClock = NS.timerClock + dt
    local timers = NS.timers
    if #timers == 0 then return end
    local due
    for i = #timers, 1, -1 do
        local t = timers[i]
        if t.at <= NS.timerClock then
            due = due or {}
            due[#due + 1] = t
            table.remove(timers, i)
        end
    end
    if not due then return end
    table.sort(due, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.seq < b.seq
    end)
    for _, t in ipairs(due) do t.fn() end
end)

NS.After = function(delay, fn)
    NS.timerSeq = NS.timerSeq + 1
    NS.timers[#NS.timers + 1] = { at = NS.timerClock + delay, fn = fn, seq = NS.timerSeq }
end

-- ============================================================
-- Whisper / raid-command send (fire-and-forget; mod-playerbots commands are
-- plain whispers, GM-style bulk commands go over SAY per CleanBot's pattern).
--
-- Chat with a bot is blocked ONLY for the brief round-trip of each
-- automated command — not permanently — so the user can still whisper bots
-- themselves the rest of the time (per explicit user direction: "мне нужно
-- помимо аддона давать команды ботам", i.e. a standing filter that hid ALL
-- chat with tracked bots got in the way of that). NS.blockedBotNames is the
-- set the chat filters (further below) actually check.
-- ============================================================
NS.blockedBotNames = {}   -- lower(name) -> true while a command round-trip is in flight

-- ============================================================
-- Detail-window fetch tracking: NS.FetchStrategy/
-- NS.FetchBotQuests/NS.RefreshBotEquipBackground are each called from BOTH
-- the background poller (NS.PollBotDetails) AND the detail window's manual
-- Refresh button. Two independent chains to the SAME bot (e.g. the poller's
-- scheduled "items" fetch landing while Refresh's own "items" fetch for
-- that same bot is still streaming in) race for the shared
-- NS.blockedBotNames chat-hiding window — whichever one's SendBotCommand
-- timer clears first re-opens the filter while the other's reply is still
-- arriving, which is exactly what leaked equip/items/quests replies into
-- visible chat (confirmed by the user in-game). This counter is what
-- NS.PollBotDetails/NS.PollBots check before enqueueing a NEW job for a
-- bot, so a fetch already in flight for it (started by either caller) is
-- never doubled up on. Reference-counted (not a boolean) since Refresh can
-- have 2 chains in flight for the same bot at once (equip + whichever
-- section's own fetch — see the refresh button's OnClick). Scoped per bot —
-- per explicit user direction, a fetch for one bot never pauses polling for
-- the rest of the roster.
-- ============================================================
NS.detailFetchCount = {}   -- lower(name) -> number of in-flight detail-window fetches

NS.BeginDetailFetch = function(botName)
    local key = strlower(botName)
    NS.detailFetchCount[key] = (NS.detailFetchCount[key] or 0) + 1
end

NS.EndDetailFetch = function(botName)
    local key = strlower(botName)
    local n = (NS.detailFetchCount[key] or 0) - 1
    if n > 0 then
        NS.detailFetchCount[key] = n
    else
        NS.detailFetchCount[key] = nil
    end
end

NS.IsDetailFetchActive = function(botName)
    return (NS.detailFetchCount[strlower(botName)] or 0) > 0
end

NS.addonWhisperAt = {}   -- lower(name) .. "|" .. command -> GetTime() the addon whispered it
NS.addonWhisperLast = {} -- lower(name) -> GetTime() of the addon's latest whisper to that bot
local function SendBotCommand(name, command)
    local key = strlower(name)
    NS.addonWhisperAt[key .. "|" .. command] = GetTime()
    NS.addonWhisperLast[key] = GetTime()
    NS.blockedBotNames[key] = true
    SendChatMessage(command, "WHISPER", nil, name)
    -- STEP_DELAY covers the round-trip (send + any reply) for every
    -- automated command this addon fires — reusing it here instead of a
    -- separate constant keeps one tunable for "how long an automated
    -- exchange with a bot takes".
    NS.After(NS.STEP_DELAY, function() NS.blockedBotNames[key] = nil end)
end
NS.SendBotCommand = SendBotCommand   -- for helpers defined above it

-- ============================================================
-- Command chains: ordered multi-step conversations with ONE bot.
--
-- SendBotCommand above stays the right tool for a lone fire-and-forget
-- whisper. A chain adds what a sequence needs, declared per step:
--
--   cmd      string, or function() -> string|nil evaluated at send time
--            (nil skips the step), or a list of strings sent back-to-back on
--            every attempt (e.g. a change command + a "?" query whose reply
--            proves the change took), `gap` seconds apart if the step sets one.
--   reply    what the bot answers: nil (it doesn't answer), a plain-text
--            substring, or function(msg) -> boolean.
--   wait     what must happen before the NEXT step goes out:
--              nil       nothing — the next step is sent right away. Use this
--                        for commands whose order or completion doesn't matter
--                        (whispers reach the server in the order sent anyway).
--              number    seconds to let the command take effect first (for
--                        commands the bot never confirms, e.g. summon/reset).
--              "reply"   the bot's matching `reply` (up to `timeout`).
--   timeout  seconds to wait for `reply` (default NS.STATS_TIMEOUT).
--   retries  extra sends if no confirmation arrives in time (default 0).
--   critical true: the step MUST be confirmed — retries run, and if it's
--            still unconfirmed the whole chain stops and opts.onFail runs.
--            Otherwise (default) an unconfirmed step is skipped and the chain
--            goes on — the "nice to have" case.
--   listen   function(msg), called with every whisper from the bot while this
--            step is current (sending, waiting, settling) — for noting what
--            the bot did without making the step wait for it.
--   verify   function() -> boolean, an extra way to confirm a step that has
--            no (or an unreliable) reply: checked when the wait/timeout
--            expires, before deciding to retry/fail.
--   A step that is `critical` or has `retries` always waits for confirmation
--   (reply, else verify after `wait`/`timeout` seconds) — unconfirmed
--   commands can't be retried blindly.
--
-- opts: onDone(), onFail(failedCmd), abortIf() (checked before every step; a
-- true result ends the chain silently — for state that changed under it),
-- key (a chain with the same key already running/queued for this bot is not
-- added again). Chains for the same bot run one at a time, in the order
-- queued; different bots never wait on each other.
-- ============================================================
NS.botChains = {}   -- lower(name) -> { running = chain|nil, queue = { chain, ... } }

local StartChain

local function FinishChain(st, chain, ok, failedCmd)
    if st.running ~= chain then return end
    chain.dead = true
    st.running = nil
    if ok == true then
        if chain.onDone then chain.onDone() end
    elseif ok == false then
        if chain.onFail then chain.onFail(failedCmd) end
    end
    -- A callback above may itself have queued/started a new chain.
    if not st.running then
        local nxt = table.remove(st.queue, 1)
        if nxt then StartChain(st, nxt) end
    end
end

local function RunStep(st, chain)
    if chain.dead then return end
    if chain.abortIf and chain.abortIf() then
        FinishChain(st, chain, nil)
        return
    end
    local step = chain.steps[chain.i]
    if not step then
        FinishChain(st, chain, true)
        return
    end
    local cmd = step.cmd
    if type(cmd) == "function" then cmd = cmd() end
    if not cmd then
        chain.i = chain.i + 1
        RunStep(st, chain)
        return
    end

    local key      = chain.key
    local retries  = step.retries or 0
    local numWait  = type(step.wait) == "number" and step.wait or nil
    local needsConfirm = step.wait == "reply" or step.critical or retries > 0
    local attempt  = 0

    local function nextStep()
        chain.awaiting = nil
        chain.verifyFn = nil
        if needsConfirm then
            Print(string.format("|cff00ff00[Chain]|r %.1f OK %s <- %s", GetTime(),
                type(cmd) == "table" and cmd[1] or cmd, chain.name), NS.ChainCategory(cmd))
        end
        chain.i = chain.i + 1
        RunStep(st, chain)
    end

    local function failStep()
        chain.awaiting = nil
        chain.verifyFn = nil
        Print(string.format("|cff00ff00[Chain]|r %.1f UNCONFIRMED %s <- %s", GetTime(),
            type(cmd) == "table" and cmd[1] or cmd, chain.name), NS.ChainCategory(cmd))
        if step.critical then
            FinishChain(st, chain, false, type(cmd) == "table" and cmd[1] or cmd)
        else
            nextStep()
        end
    end

    local function send()
        attempt = attempt + 1
        chain.token = chain.token + 1
        local token = chain.token
        chain.listen = step.listen
        Print(string.format("|cff00ff00[Chain]|r %.1f SEND %s (try %d/%d) -> %s",
            GetTime(), type(cmd) == "table" and table.concat(cmd, " | ") or cmd,
            attempt, retries + 1, chain.name), NS.ChainCategory(cmd))
        if type(cmd) == "table" then
            -- First command now; the rest `gap` seconds apart (default 0),
            -- skipped if the attempt was superseded/cancelled meanwhile.
            for i, c in ipairs(cmd) do
                if i == 1 or not step.gap then
                    SendBotCommand(chain.name, c)
                else
                    NS.After(step.gap * (i - 1), function()
                        if chain.token == token and not chain.dead then
                            SendBotCommand(chain.name, c)
                        end
                    end)
                end
            end
        else
            SendBotCommand(chain.name, cmd)
        end

        if not needsConfirm then
            if numWait then
                NS.After(numWait, function()
                    if chain.token == token and not chain.dead then nextStep() end
                end)
            else
                nextStep()
            end
            return
        end

        local waitFor = step.reply ~= nil and (step.timeout or NS.STATS_TIMEOUT)
            or numWait or step.timeout or NS.STATS_TIMEOUT
        if step.reply ~= nil then
            -- Hide the reply for as long as we're listening for it (the
            -- default SendBotCommand window is only STEP_DELAY).
            NS.blockedBotNames[key] = true
            NS.After(waitFor, function() NS.blockedBotNames[key] = nil end)
            chain.awaiting = {
                match = step.reply,
                onReply = function()
                    if chain.token ~= token or chain.dead then return end
                    chain.awaiting = nil
                    if numWait then
                        NS.After(numWait, function()
                            if chain.token == token and not chain.dead then nextStep() end
                        end)
                    else
                        nextStep()
                    end
                end,
            }
        end
        if step.verify then
            -- Polled by chainPoller below: confirms the step the moment
            -- verify() turns true instead of only when the wait runs out.
            chain.verifyFn = step.verify
            chain.onVerified = function()
                if chain.token ~= token or chain.dead then return end
                nextStep()
            end
        end
        NS.After(waitFor, function()
            if chain.token ~= token or chain.dead then return end
            chain.awaiting = nil
            chain.verifyFn = nil
            if step.verify and step.verify() then
                nextStep()
            elseif attempt <= retries then
                send()
            else
                failStep()
            end
        end)
    end
    send()
end

StartChain = function(st, chain)
    st.running = chain
    RunStep(st, chain)
end

--- Queues `steps` (see the block comment above) for one bot. Returns false
--- if a chain with opts.key is already running/queued for it.
NS.SendBotChain = function(name, steps, opts)
    opts = opts or {}
    local key = strlower(name)
    local st = NS.botChains[key]
    if not st then
        st = { queue = {} }
        NS.botChains[key] = st
    end
    if opts.key then
        if st.running and st.running.tag == opts.key then return false end
        for _, c in ipairs(st.queue) do
            if c.tag == opts.key then return false end
        end
    end
    local chain = {
        key = key, name = name, steps = steps, i = 1, token = 0,
        tag = opts.key, onDone = opts.onDone, onFail = opts.onFail,
        abortIf = opts.abortIf,
    }
    if st.running then
        st.queue[#st.queue + 1] = chain
    else
        StartChain(st, chain)
    end
    return true
end

--- Drops this bot's running and queued chains without calling onDone/onFail
--- (steps already sent can't be unsent).
NS.CancelBotChains = function(name)
    local st = NS.botChains[strlower(name)]
    if not st then return end
    if st.running then st.running.dead = true end
    st.running = nil
    st.queue = {}
end

-- Feeds incoming bot whispers to the chain step currently waiting on a reply.
-- A separate watcher, not part of the big one below: every CHAT_MSG_WHISPER
-- frame sees every whisper, so this never competes with them.
local chainWatcher = CreateFrame("Frame")
chainWatcher:RegisterEvent("CHAT_MSG_WHISPER")
chainWatcher:SetScript("OnEvent", function(self, event, msg, sender)
    local st = NS.botChains[strlower(sender or "")]
    local chain = st and st.running
    if chain and chain.listen then chain.listen(msg) end   -- step.listen: sees every whisper while the step is current
    local aw = chain and chain.awaiting
    if not aw then return end
    local m = aw.match
    local hit
    if type(m) == "function" then hit = m(msg) else hit = strfind(msg, m, 1, true) end
    if hit then
        aw.onReply()
    elseif msg:match("^Strategies:") then
        -- Only a strategy list that didn't contain what the step wanted is
        -- worth showing — any other whisper that arrives while a step waits
        -- (stats, rpg status, ...) is unrelated noise.
        Print(string.format("|cff00ff00[Chain]|r %.1f reply not matching <- %s: %s",
            GetTime(), sender, strsub(msg, 1, 160)), "strategies")
    end
end)

-- One shared 4Hz poll for every chain step waiting on a verify() — a single
-- frame, since frames created with CreateFrame are never garbage-collected
-- (per-poll NS.After frames would pile up).
local chainPoller = CreateFrame("Frame")
local chainPollElapsed = 0
chainPoller:SetScript("OnUpdate", function(self, dt)
    chainPollElapsed = chainPollElapsed + dt
    if chainPollElapsed < 0.25 then return end
    chainPollElapsed = 0
    for _, st in pairs(NS.botChains) do
        local chain = st.running
        local fn = chain and not chain.dead and chain.verifyFn
        if fn and fn() then
            chain.verifyFn = nil
            chain.onVerified()
        end
    end
end)

--- Broadcasts a command to the whole party/raid via chat — every currently
--- grouped bot reacts at once (mirrors CleanBot's CB_SendGroupCommand).
--- Powers the action bar's pet-style Attack/Follow/Stay/Aggressive/
--- Defensive/Passive buttons. Only reaches bots already in the player's OWN
--- group — unlike ResetStrayGroups' per-bot whisper, this has no way to
--- reach a bot stuck in someone else's group, but that's a rare recovery
--- case, not what these buttons are for.
NS.groupSent = {}   -- command text -> GetTime() the addon last sent it to the group
local function SendGroupCommand(cmd)
    NS.groupSent[cmd] = GetTime()
    if GetNumRaidMembers() > 0 then
        SendChatMessage(cmd, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendChatMessage(cmd, "PARTY")
    else
        Print("You are not in a party or raid.")
    end
end

--- Sets the whole group's combat reaction to one of the 3 mutually
--- exclusive states (see NS.REACTION_* above) and persists the choice.
--- mod-playerbots exposes Aggressive and Passive as "co" strategy flags;
--- Defensive is simply having neither flag set — the same "+sel,-other"
--- pattern CleanBot uses for its movement toggles.
local function ApplyReaction(reaction)
    AltBot_SavedVars = AltBot_SavedVars or {}
    if reaction ~= NS.REACTION_AGGRESSIVE and reaction ~= NS.REACTION_PASSIVE then
        reaction = NS.REACTION_DEFENSIVE
    end
    AltBot_SavedVars.reaction = reaction
    SendGroupCommand(NS.ReactionCommand(reaction))
    if NS.RefreshActionBar then NS.RefreshActionBar() end
end
NS.ApplyReaction = ApplyReaction

--- This character's own saved reaction, defaulting to Defensive (nil reads
--- the same way) — mirrors NS.EffectiveMode's "no explicit choice yet"
--- handling.
-- Movement (follow/stay) and reaction (aggressive/defensive/passive) are ACCOUNT-wide, like the mode: what
-- one master sets is what the next master loads with, and the raid is put into that state after it has
-- been formed (see NS.SavedStanceSteps) - per explicit user direction.
NS.EffectiveReaction = function()
    return (AltBot_SavedVars and AltBot_SavedVars.reaction) or NS.REACTION_DEFENSIVE
end

--- This character's own saved movement, defaulting to Follow (nil reads
--- the same way).
NS.EffectiveMovement = function()
    return (AltBot_SavedVars and AltBot_SavedVars.movement) or NS.MOVEMENT_FOLLOW
end

--- The group command that brings a bot into the saved movement / reaction state.
NS.MovementCommand = function()
    return NS.EffectiveMovement() == NS.MOVEMENT_STAY and "stay" or "follow"
end
NS.ReactionCommand = function(reaction)
    reaction = reaction or NS.EffectiveReaction()
    if reaction == NS.REACTION_AGGRESSIVE then return "co +aggressive,-passive" end
    if reaction == NS.REACTION_PASSIVE then return "co -aggressive,+passive" end
    return "co -aggressive,-passive"
end

--- Chain steps that put ONE bot into the saved movement + reaction (after its botAI was reset).
NS.SavedStanceSteps = function()
    return {
        { cmd = function() return NS.MovementCommand() end },
        { cmd = function() return NS.ReactionCommand() end },
    }
end

-- ============================================================
-- Group helpers. Covers BOTH a raid and a plain party — the group starts as
-- a party (created by the first bot join) and gets converted to a raid
-- mid-grouping, so callers need to see whichever kind is currently active.
-- ============================================================

--- Iterates group members, skipping offline ones by default. WoW keeps a
--- disconnected member's slot around for a while (shown as "Вышел из..."
--- in the party frame) — UnitName/UnitIsPlayer/UnitLevel/UnitClass all
--- still answer for that stale slot, only UnitIsConnected says no. Without
--- this filter every caller (ScanCurrentGroup, MissingRosterNames,
--- PollBots, ...) treated a bot that had actually dropped/logged out as
--- still "grouped": MissingRosterNames never saw it as missing so
--- GroupRoster never re-added it, and pollers kept whispering it anyway,
--- bouncing back as "Character ... not found" forever (confirmed by the
--- user in-game after a server restart). Pass includeOffline = true only
--- when you specifically need to see/clear those stale slots (see
--- KickOfflineTrackedBots below).
---@param fn fun(unit: UnitId|string, name: string?)
---@param includeOffline boolean?
local function ForEachGroupMember(fn, includeOffline)
    local masterPlaced = false
    local nRaid = GetNumRaidMembers()
    if nRaid > 0 then
        for i = 1, nRaid do
            local unit = "raid" .. i
            if not UnitIsUnit(unit, "player") and (includeOffline or UnitIsConnected(unit)) then
                fn(unit, UnitName(unit))
            end
        end
        return
    end

    local nParty = GetNumPartyMembers()
    for i = 1, nParty do
        local unit = "party" .. i
        if not UnitIsUnit(unit, "player") and (includeOffline or UnitIsConnected(unit)) then
            fn(unit, UnitName(unit))
        end
    end
end

--- True if this bot is alive and close enough to the master to trade with
--- (CheckInteractDistance index 2, ~11 yards) — what "summon actually
--- worked" means here, per explicit user direction ("суммон успешен, если с
--- ботом можно торговать"). False for a bot not in the group/offline too.
NS.BotNearMaster = function(name)
    local key = strlower(name)
    local near = false
    ForEachGroupMember(function(unit, n)
        if n and strlower(n) == key
            and not UnitIsDeadOrGhost(unit)
            and CheckInteractDistance(unit, 2) then
            near = true
        end
    end)
    return near
end

--- Sets/clears a bot's "individually summoned and parked" mark
--- (entry.farmHeld) AND persists it per character (NS.CharVars().farmHeld,
--- keyed by lowercase bot name) so it survives /reload — BuildRosterFromNames
--- restores it, ApplyStrategyForMode keeps those bots parked and re-summons
--- them if they aren't at the master.
NS.SetFarmHeld = function(entry, on)
    entry.farmHeld = on and true or nil
    local cv = NS.CharVars()
    cv.farmHeld = cv.farmHeld or {}
    cv.farmHeld[strlower(entry.name)] = entry.farmHeld
end

--- Whether a bot's bags window may do Trade/Sell/Equip/etc right now. Outside
--- Farm mode always. In Farm mode only for a bot parked via the board's top
--- row (entry.farmHeld, i.e. individually summoned) that is also actually
--- tradeable at this moment (NS.BotNearMaster) — every other grinding bot has
--- no reachable vendor/trade partner, so its bags window stays view-only.
NS.CanWorkBotBags = function(botName)
    if AltBot_SavedVars.mode ~= NS.MODE_FARM then return true end
    local entry = NS.bots[strlower(botName)]
    return entry ~= nil and entry.farmHeld == true and NS.BotNearMaster(botName)
end

--- Critical chain step: "reset botAI", confirmed by the bot's own "AI was
--- reset to defaults" reply; no reply within STEP_DELAY -> sent again, up to
--- 3 more times, then the chain stops (its onFail runs). Per explicit user
--- direction: moving a bot between Farm and Quest must be verified.
NS.ResetStep = function()
    return {
        cmd = "reset botAI", critical = true, retries = 3,
        wait = "reply", timeout = NS.STEP_DELAY,
        reply = "AI was reset to defaults",
    }
end

--- Critical chain step: put the bot on the Farm strategy. The change command
--- gets no reply and "rpg status" can't confirm it (a bot reset by "reset
--- botAI" still reports its old grind status), so it's sent together with
--- "nc ?" and counts as done only when the answering "Strategies: ..." list
--- contains "new rpg"; otherwise both are sent again, up to 3 more times,
--- then the chain stops.
NS.FarmStrategyStep = function()
    return {
        cmd = { NS.RESTORE_STRATEGY, "nc ?" }, gap = 0.3, critical = true, retries = 3,
        wait = "reply", timeout = NS.STEP_DELAY,
        reply = function(msg)
            return strsub(msg, 1, 12) == "Strategies: " and strfind(msg, "new rpg", 1, true) ~= nil
        end,
    }
end

--- Two chain steps: sell the bot's junk, then — ONLY if the bot actually
--- reported selling something — ask for "stats" so the board's bag count is
--- refreshed right away; no sale, no extra "stats". `settle` is how long the
--- sell step lets replies come in before the decision. The sale is recognised
--- by the bot's reply starting with "Selling"/"Sold" (wording not confirmed
--- in-game yet — if it differs, no extra stats is sent, which is the same as
--- before). Per explicit user direction.
NS.SellAndRecheckSteps = function(settle, entry)
    local sold = false
    return {
        { cmd = function()
              sold = false
              if entry then entry.stepTimer = 0 end
              return NS.SellCommand()
          end, wait = settle,
          listen = function(msg)
              if msg:match("^[Ss]elling") or msg:match("^[Ss]old") then sold = true end
          end },
        { cmd = function() return sold and "stats" or nil end },
    }
end

--- Chain step that summons `entry` and counts as done only once the bot is
--- tradeable (NS.BotNearMaster). A summon is an instant teleport, so a bot
--- still not tradeable after `wait` means the summon didn't take — it's sent
--- again, up to 3 more times, then the chain stops (critical) and its
--- onFail runs. `wait` is 0.1s per explicit user direction ("не надо ждать,
--- ну может 0.1, не больше").
--- BotNearMaster, plus: the first time a bot is seen next to the master in a session,
--- its armory model gets loaded in the background (NS.WarmArmoryModel).
NS.NearAndWarm = function(name)
    local ok = NS.BotNearMaster(name)
    if ok and NS.WarmArmoryModel then NS.WarmArmoryModel(name) end
    return ok
end

NS.SummonStep = function(entry)
    return {
        cmd = "summon", critical = true, retries = 3, wait = 0.1,
        verify = function() return NS.NearAndWarm(entry.name) end,
    }
end

--- True if any current group slot is a tracked bot that's currently
--- offline (see ForEachGroupMember's doc comment for why this needs its
--- own includeOffline=true pass rather than reusing the normal one).
local function HasOfflineTrackedBots()
    local found = false
    ForEachGroupMember(function(unit, name)
        if name and NS.bots[strlower(name)] and not UnitIsConnected(unit) then
            found = true
        end
    end, true)
    return found
end

-- ============================================================
-- Textarea parsing: one space-separated blob of tokens, case-insensitive.
-- Filters out the player's own name and "-comment" tokens, splits off class
-- tokens (English/Russian, see CLASS_NAME_ALIASES) into a separate list for
-- ".playerbots bot addclass", and caps the remaining bot names at
-- NS.MAX_BOTS. See the file header for the full spec.
-- ============================================================

--- Truncates every line at its first Lua-style "--" — whether the line IS
--- the comment ("-- скип этого бота") or just TRAILS one after real content
--- ("zara -- воин", where "воин" is a note about zara, not a class token to
--- act on). Runs BEFORE newlines get collapsed to spaces — once collapsed,
--- a "--" would just be sitting mid-blob with no line boundary left to
--- anchor "everything after this to the next newline is a comment".
--- Distinct from ParseRosterText's "-" token filter (a different mechanism:
--- that one drops one whole space-separated TOKEN starting with a single
--- "-", e.g. "-x"; this one drops from "--" to end-of-line, checked first
--- while lines still exist).
---@param text string  Raw (possibly multi-line) textarea text.
---@return string       Text with "--"-comments truncated, newlines intact.
local function StripCommentLines(text)
    local kept = {}
    for line in (text or ""):gmatch("([^\n]*)\n?") do
        local dashes = strfind(line, "--", 1, true)
        kept[#kept + 1] = dashes and strsub(line, 1, dashes - 1) or line
    end
    return table.concat(kept, "\n")
end

--- Collapses newlines to spaces (the roster can be typed across multiple
--- lines — see the file header) and any run of 2+ consecutive spaces down
--- to a single space, before parsing/redisplay. Comment lines (StripCommentLines)
--- must run first — see its doc comment for why.
local function NormalizeSpaces(text)
    text = StripCommentLines(text)
    text = text:gsub("[\r\n]+", " ")
    return text:gsub("  +", " ")
end

--- Splits raw textarea text into { botNames = {...}, classCounts = {...} }.
--- botNames preserves the original casing/spelling as typed (display name,
--- whisper target); classCounts maps each recognized class token's canonical
--- ".playerbots bot addclass" argument to how many times it appeared — e.g.
--- "дк дк" (2 tokens) means "the raid should contain 2 wild death knights",
--- a standing quota re-checked on every sync, not a one-shot count. Named
--- bots are independent of class quotas even when their own class matches
--- (confirmed by the user): a named warrior "Pupsik" does NOT count toward
--- a "warrior" quota.
local function ParseRosterText(text)
    text = NormalizeSpaces(text)
    local playerKey = strlower(UnitName("player") or "")
    local botNames, classCounts = {}, {}
    -- Raid-slot order as typed (master token / bot name / wild-class token), used to
    -- arrange raid subgroups: every 5 slots = one group (per explicit user direction).
    local slots, masterSeen = {}, false

    for token in (text or ""):gmatch("%S+") do
        local lower = strlower(token)
        if lower == playerKey then
            -- the player themselves — not a bot, but his token fixes his place in the raid
            if not masterSeen then
                masterSeen = true
                slots[#slots + 1] = { master = true }
            end
        elseif strsub(lower, 1, 1) == "-" then
            -- "-comment" token — filtered out
        elseif NS.CLASS_NAME_ALIASES[lower] then
            local className = NS.CLASS_NAME_ALIASES[lower]
            classCounts[className] = (classCounts[className] or 0) + 1
            slots[#slots + 1] = { class = className }
        else
            if #botNames < NS.MAX_BOTS then
                -- Capitalize the first letter here, once, at parse time —
                -- per explicit user direction, typing the roster textarea
                -- all-lowercase stays convenient, but character names are
                -- case-sensitive to the server for whispers and
                -- ".playerbots bot add/remove", so the stored name must
                -- already be in the server-correct form everywhere else in
                -- the file uses it (display, whisper, bot add/remove) rather
                -- than each call site fixing it up individually. Class-count
                -- tokens (the `elseif NS.CLASS_NAME_ALIASES` branch above)
                -- are deliberately NOT touched — they're never sent to the
                -- server as a name.
                botNames[#botNames + 1] = token:sub(1, 1):upper() .. token:sub(2)
                slots[#slots + 1] = { name = botNames[#botNames] }
            end
        end
    end
    -- No master token in the roster: he goes first (group 1).
    if not masterSeen then table.insert(slots, 1, { master = true }) end

    return { botNames = botNames, classCounts = classCounts, slots = slots }
end

--- The mode to actually treat as active: the account-wide saved mode,
--- UNLESS the (shared) roster is empty, in which case this always reads as
--- nil regardless of what's stored — an empty roster means "not configured
--- yet" even if a mode was saved during an earlier, since-cleared session
--- (confirmed by the user: "сбрасывать mode, когда ростер пуст"). Both
--- RefreshForm (button highlighting) and ApplyMode (the fresh-install
--- no-op guard) read through this instead of AltBot_SavedVars.mode
--- directly, so they can never disagree about whether a mode is "really"
--- active.
---
--- mode is account-wide (AltBot_SavedVars.mode), NOT per-character
--- (NS.CharVars) — per explicit user direction: "режим моды должен быть
--- один для аккаунта, какой был у предыдущего мастера, такой должен быть у
--- любого другого нового, пока какой-то мастер не поменяет". It used to
--- live in NS.CharVars(), which meant a Disband done under one master
--- character was invisible to every other character on the account — the
--- stats board came back full of stale "?" columns on login as a DIFFERENT
--- master, because that character's own (never-set) per-character mode
--- read as nil/Quest/Farm instead of the Solo state the account was
--- actually left in (confirmed by the user in-game).
---
--- Defined here (not near the top of the file, where it originally lived)
--- because it needs ParseRosterText, which is a `local function` declared
--- just above — Lua resolves upvalues lexically at compile time, so a
--- local declared LATER in the file is never visible to a function defined
--- earlier, even though the earlier one only actually runs (much later, on
--- some button click) after the whole file has finished loading. That's not
--- a version quirk — the file's own DisbandRoster/StartNextInQueue-forward-
--- reference pattern only works because those are called via NS.-prefixed
--- fields resolved at call time, not because Lua magically closes over
--- later locals.
NS.EffectiveMode = function()
    if not AltBot_SavedVars then return nil end
    -- botNames is derived, in-memory state now (see BuildRosterFromNames'
    -- own doc comment) — re-parse rosterText directly here rather than
    -- trusting NS.currentBotNames, which may still be nil/stale if this
    -- runs before BuildRosterFromNames has ever been called this session.
    local names = ParseRosterText(AltBot_SavedVars.rosterText or "").botNames
    if not names or #names == 0 then return nil end
    return AltBot_SavedVars.mode
end

--- Rebuilds NS.bots/NS.rosterOrder — and, as of this rewrite, botNames/
--- classCounts themselves — from AltBot_SavedVars.rosterText (the ONE
--- account-wide source of truth for "what's typed in the Roster textarea").
---
--- Previously botNames/classCounts were computed by ParseRosterText once, at
--- Save time, and just persisted as their own separate fields from then on —
--- which meant whichever character happened to be the master WHEN Save was
--- last clicked got permanently excluded from botNames (correct — you don't
--- track yourself), but nobody ELSE'S Save re-ran ParseRosterText to put that
--- name back in once a DIFFERENT character became master. The roster text
--- itself still said all 9 names; the persisted botNames array quietly
--- stayed one short forever, until someone happened to click Save again
--- under a master where that name wasn't excluded (confirmed by the user
--- in-game: "Dara" — a former master — never reappeared in the tracked
--- roster after switching to a different master, even though the textarea
--- still listed her). Per explicit user direction ("текст ростера всегда из
--- 9 персонажей, но почему сейчас рейд из 8ми?" / "считать botNames из
--- rosterText каждый раз"): re-parsing on every BuildRosterFromNames call
--- (every login/reload/mode-apply, not just Save) means botNames/
--- classCounts can never go stale relative to rosterText — whichever
--- character is master right now is excluded fresh each time, and switching
--- masters alone (no Save needed) is what brings the previous master back in
--- as a tracked bot.
---
--- Preserves existing NS.bots entries (and their live stats/step) for names
--- still present; drops entries for names no longer in the list; adds fresh
--- entries for new names. This is the single source of truth for "who is
--- tracked" across all 3 modes.
local function BuildRosterFromNames()
    AltBot_SavedVars = AltBot_SavedVars or {}

    -- botNames/classCounts are deliberately NOT written into AltBot_SavedVars
    -- (i.e. never persisted to disk) — only NS.currentBotNames/
    -- NS.currentClassCounts, in-memory derived state recomputed from
    -- rosterText every time this runs. Persisting them at all was what
    -- caused the staleness bug in the first place (see this function's own
    -- doc comment above); per explicit user direction ("конечно же имена
    -- ботов нужно вычислять каждый раз заново и нигде не хранить, храним мы
    -- только текст ростера и моду... больше нам ничего хранить не нужно
    -- между сессиями"), rosterText and mode are the only roster-related
    -- fields that persist between sessions at all.
    local parsed = ParseRosterText(AltBot_SavedVars.rosterText or "")
    NS.currentBotNames    = parsed.botNames
    NS.currentClassCounts = parsed.classCounts
    NS.currentSlots       = parsed.slots

    local names = NS.currentBotNames or {}
    local wanted = {}
    for _, name in ipairs(names) do wanted[strlower(name)] = name end

    -- Drop entries no longer wanted (wild-class bots are kept: NS.SyncWildBots owns them).
    for key in pairs(NS.bots) do
        if not wanted[key] and not NS.bots[key].wild then
            NS.bots[key] = nil
            if NS.StopBotPollLoop then NS.StopBotPollLoop(key) end
        end
    end

    -- Spread every NEW bot's own poll-loop initial start evenly across the
    -- full NS.POLL_INTERVAL (not a flat small constant) — per explicit user
    -- direction ("равномерно по 30с / число ботов"): with #names known
    -- up front, NS.STAGGER_DELAY can be the real per-roster step instead of
    -- a fixed 0.4s, which for a small roster barely spread the starts out at
    -- all (confirmed by the user in-game: "при старте все циклы запустились
    -- одновременно"). NS.StartBotPollLoop reads this same field for each
    -- bot's own initial-delay calculation.
    if #names > 0 then
        NS.STAGGER_DELAY = NS.POLL_INTERVAL / #names
    end

    local keepWild = {}
    for _, k in ipairs(NS.rosterOrder) do
        if NS.bots[k] and NS.bots[k].wild then keepWild[#keepWild + 1] = k end
    end
    NS.rosterOrder = {}
    for _, name in ipairs(names) do
        local key = strlower(name)
        if not NS.bots[key] then
            NS.bots[key] = { name = name, step = "idle", stepTimer = 0 }
            NS.RestoreBotStats(NS.bots[key])
            -- Individually summoned (parked) bots survive /reload — see
            -- NS.SetFarmHeld. Only meaningful while the saved mode is Farm.
            local held = NS.CharVars().farmHeld
            if held and held[key] and AltBot_SavedVars.mode == NS.MODE_FARM then
                NS.bots[key].farmHeld = true
            end
        end
        NS.rosterOrder[#NS.rosterOrder + 1] = key
        -- Starts this bot's own independent poll loop exactly once, ever,
        -- the first time it's seen (no-op on every later BuildRosterFromNames
        -- call for the same bot) — see NS.StartBotPollLoop's own doc comment.
        NS.StartBotPollLoop(key)
    end
    for _, k in ipairs(keepWild) do NS.rosterOrder[#NS.rosterOrder + 1] = k end
end

-- ============================================================
-- Grouping (all modes): take the tracked bot-names list, ".playerbots bot
-- add" the first 4 to form/confirm a party, check whether it qualifies to
-- convert to a raid, and either convert + add the rest, or leave the party
-- of 4 alone. Runs from NS.ApplyMode for every mode — the mode only affects
-- what happens to bots afterward (strategy, bag-checking), not whether they
-- get summoned into the world.
-- ============================================================

--- True if BOTH the player AND at least one other party member are at or
--- above the raid-conversion level threshold — the actual server-side
--- ConvertToRaid precondition (confirmed by the user, not assumed): "смотрим,
--- что лвл плеера >= 10 и есть хотя бы один бот с лвл >= 10".
local function PartyQualifiesForRaid()
    local playerLevel = UnitLevel("player")
    if not playerLevel or playerLevel < NS.RAID_CONVERT_MIN_LEVEL then
        return false
    end

    local botQualifies = false
    ForEachGroupMember(function(unit, name)
        if name and UnitIsPlayer(unit) then
            local level = UnitLevel(unit)
            if level and level >= NS.RAID_CONVERT_MIN_LEVEL then
                botQualifies = true
            end
        end
    end)
    return botQualifies
end

--- Waits for the group roster to stop growing (NS.DISCOVER_SETTLE seconds
--- unchanged, capped at NS.DISCOVER_TIMEOUT), tracking size across party+raid
--- together since the group can convert from one to the other mid-wait.
--- Calls onSettled() once settled/timed out.
local function WaitForGroupToSettle(onSettled)
    local elapsed       = 0
    local settleElapsed  = 0
    local function GroupSize() return GetNumRaidMembers() + GetNumPartyMembers() end
    local lastCount = GroupSize()
    local STEP = 0.25
    local function poll()
        elapsed = elapsed + STEP
        local count = GroupSize()
        if count ~= lastCount then
            lastCount     = count
            settleElapsed = 0
        else
            settleElapsed = settleElapsed + STEP
        end
        local settled  = settleElapsed >= NS.DISCOVER_SETTLE
        local timedOut = elapsed >= NS.DISCOVER_TIMEOUT
        if not settled and not timedOut then
            NS.After(STEP, poll)
            return
        end
        onSettled()
    end
    NS.After(STEP, poll)
end

--- Reads class/level off whoever's currently grouped and updates the
--- MATCHING entries already in NS.bots (built from the textarea — see
--- BuildRosterFromNames) — does NOT create or remove tracked bots, since the
--- textarea is the single source of truth for who's tracked, not the live
--- group (a bot can be tracked while not currently grouped, e.g. in Quest
--- mode, which never groups at all). entry.class is stamped as the
--- UnitClass englishClass token (e.g. "WARRIOR") — RAID_CLASS_COLORS and
--- CLASS_ICON_TCOORDS are both keyed that way.
local function ScanCurrentGroup()
    NS.SyncWildBots()
    local seen = 0
    ForEachGroupMember(function(unit, name)
        if name and UnitIsPlayer(unit) then
            local entry = NS.bots[strlower(name)]
            if entry then
                entry.level = UnitLevel(unit)
                local _, englishClass = UnitClass(unit)
                entry.class = englishClass
                seen = seen + 1
            end
        end
    end)
    -- (No "Grouped/updated N" line — the single mode line printed once
    -- ApplyMode finishes already says how many bots are tracked.)
    -- A bot that's ALREADY dead/ghost at the moment it (re)joins the group
    -- won't necessarily fire a fresh UNIT_HEALTH on its own (its health just
    -- sits at 0, unchanged) — NS.CheckReviveBots is event-driven now (see its
    -- own doc comment), so this full sweep right after (re)grouping is what
    -- catches that "already dead when grouped" case instead of leaving it
    -- stuck waiting for a health change that may never come.
    NS.CheckReviveBots()
    if NS.RefreshPanel then NS.RefreshPanel() end
end

--- Maps a WoW englishClass token (UnitClass's 2nd return, e.g. "DEATHKNIGHT")
--- to the lowercase canonical form used by NS.CLASS_NAME_ALIASES' values
--- and ".playerbots bot addclass" (e.g. "deathknight").
local function CanonicalClassOf(unit)
    local _, englishClass = UnitClass(unit)
    return englishClass and strlower(englishClass) or nil
end

-- ------------------------------------------------------------------
-- Wild-class bots (the roster's class tokens like "dk", "warlock"): the group members that fill
-- a class quota are tracked like named bots - board column, stats/items polling, windows - per
-- explicit user direction. They live in NS.bots with entry.wild = true (named-ness checks above
-- look at that flag). Their caches are NOT kept across sessions: every key they ever used is
-- wiped from the saved variables at logout.
-- ------------------------------------------------------------------
NS.wildNames = {}   -- every wild bot key seen this session

NS.SyncWildBots = function()
    if NS.EffectiveMode() == NS.MODE_SOLO then return end
    local needed = {}
    for className, count in pairs(NS.currentClassCounts or {}) do needed[className] = count end
    local present, order = {}, {}
    ForEachGroupMember(function(unit, name)
        if not name then return end
        local key = strlower(name)
        local e = NS.bots[key]
        if e and not e.wild then return end   -- a named bot
        local class = CanonicalClassOf(unit)
        if class and needed[class] and needed[class] > 0 then
            needed[class] = needed[class] - 1
            present[key] = true
            order[#order + 1] = key
            if not e then
                local _, englishClass = UnitClass(unit)
                NS.bots[key] = { name = name, step = "idle", stepTimer = 0, wild = true,
                    class = englishClass, level = UnitLevel(unit) }
                NS.wildNames[key] = true
            end
        end
    end)
    -- gone wild bots out (collected first: no key changes while pairs() walks the table)
    local gone
    for key, e in pairs(NS.bots) do
        if e.wild and not present[key] then
            gone = gone or {}
            gone[#gone + 1] = key
        end
    end
    for _, key in ipairs(gone or {}) do
        NS.bots[key] = nil
        if NS.StopBotPollLoop then NS.StopBotPollLoop(key) end
    end
    -- roster order: named bots as typed, then the wild ones as they sit in the group
    local newOrder = {}
    for _, k in ipairs(NS.rosterOrder) do
        if NS.bots[k] and not NS.bots[k].wild then newOrder[#newOrder + 1] = k end
    end
    for _, k in ipairs(order) do newOrder[#newOrder + 1] = k end
    NS.rosterOrder = newOrder
    if #newOrder > 0 then NS.STAGGER_DELAY = NS.POLL_INTERVAL / #newOrder end
    for _, k in ipairs(order) do NS.StartBotPollLoop(k) end   -- no-op for one already running
end

NS.wildLogoutFrame = CreateFrame("Frame")
NS.wildLogoutFrame:RegisterEvent("PLAYER_LOGOUT")
NS.wildLogoutFrame:SetScript("OnEvent", function()
    local sv = AltBot_SavedVars
    if not sv then return end
    for key in pairs(NS.wildNames) do
        for _, field in ipairs({ "bagsCache", "equipCache", "equipLinks", "botWho", "xpHour", "questTodo", "spellCache", "botStats", "trackFlags", "questCache" }) do
            if sv[field] then sv[field][key] = nil end
        end
        for _, byKey in pairs(sv.windowPoints or {}) do byKey[key] = nil end
        local held = NS.CharVars().farmHeld
        if held then held[key] = nil end
    end
end)

--- Kicks every current group member whose name is NOT in NS.bots (the named
--- roster just rebuilt from the textarea) AND who isn't needed to fill a
--- wild-class quota (NS.currentClassCounts) — logs kicked names out
--- of the world too via ".playerbots bot remove". Named-roster membership is
--- purely by name (a named bot's own class never matters here); wild-class
--- membership is purely by class headcount among the NOT-named group members
--- (independent of the named check, per explicit user direction). Runs
--- before adding the roster's own names so kicked slots free up room in a
--- party of 4 before ConvertToRaid math runs.
--- @return table  classCounts still short after keeping existing wilds, e.g. { warrior = 1 } meaning 1 more warrior is needed.
local function KickExtras()
    local classCounts = NS.currentClassCounts or {}
    local classNeeded = {}
    for className, count in pairs(classCounts) do classNeeded[className] = count end

    local extraNames = {}
    ForEachGroupMember(function(unit, name)
        if not name or (NS.bots[strlower(name)] and not NS.bots[strlower(name)].wild) then return end
        -- Not a named-roster bot — check whether its class still has an
        -- open wild-quota slot; claim one slot if so, otherwise it's extra.
        local class = CanonicalClassOf(unit)
        if class and classNeeded[class] and classNeeded[class] > 0 then
            classNeeded[class] = classNeeded[class] - 1
        else
            extraNames[#extraNames + 1] = name
        end
    end)

    if #extraNames > 0 then
        Print("Removing " .. #extraNames .. " character(s) not in the roster: "
            .. table.concat(extraNames, ", "))
        for _, name in ipairs(extraNames) do
            UninviteUnit(name)
        end
        SendChatMessage(".playerbots bot remove " .. table.concat(extraNames, ","), "SAY")
    end

    return classNeeded
end

--- Sends ".playerbots bot addclass <className>" once for each still-short
--- class quota left over after KickExtras claimed existing wild bots against
--- it — brings the wild-bot headcount per class up to what the roster's
--- class tokens require (e.g. 2 "дк" tokens = 2 wild death knights total).
local function TopUpWildClasses(classNeeded)
    for className, missing in pairs(classNeeded) do
        for _ = 1, missing do
            -- The server takes "dk" for a death knight ("Invalid Class" for "deathknight"; the
            -- MultiBot addon sends the same), every other class by its plain English name.
            SendChatMessage(".playerbots bot addclass " .. (className == "deathknight" and "dk" or className), "SAY")
        end
        if missing > 0 then
            Print("Adding " .. missing .. " wild " .. className .. "(s) to match the roster quota.")
        end
    end
end

--- Names from the roster (in order) that are NOT currently in the group —
--- the "add" side of the diff, mirroring KickExtras' "remove" side. Both
--- together mean GroupRoster only ever sends .playerbots bot add/remove for
--- the actual delta versus the live group, never for names already present
--- — so adding one new name to the textarea adds just that one bot, not a
--- re-send of everyone already grouped. A full-from-scratch add (every
--- roster name) is just the case where the group is empty to begin with —
--- there's no separate "no raid yet" branch, the diff against an empty
--- group naturally equals the whole roster. A bot already spawned in the
--- world but not currently grouped (e.g. group got disbanded) still counts
--- as "missing" here and gets re-added via .playerbots bot add, which just
--- groups the existing bot rather than recreating it.
local function MissingRosterNames(names)
    local present = {}
    ForEachGroupMember(function(unit, name)
        if name then present[strlower(name)] = true end
    end)
    local missing = {}
    for _, name in ipairs(names) do
        if not present[strlower(name)] then
            missing[#missing + 1] = name
        end
    end
    return missing
end

--- Read-only check: true if the CURRENT live group already exactly matches
--- the saved roster — every named bot present, no extra members beyond
--- named-roster/wild-class-quota bots, and no stale offline slots (see
--- HasOfflineTrackedBots' own doc comment for why that needs its own check).
--- Used by the login/reload handler to decide whether a full leave-and-
--- regroup pass is actually needed (per explicit user direction: "/reload
--- не должен вызывать пересборку ростера... если ростер не менялся, вся
--- группа в том составе который соответствует ростеру, то ничего
--- пересобирать не нужно"). Mirrors KickExtras' own extra-member logic
--- exactly, but read-only — no UninviteUnit/SendChatMessage side effects,
--- since this only answers "would there be anything to fix", not "fix it".
local function RosterMatchesGroup(names)
    if HasOfflineTrackedBots() then return false end
    if #MissingRosterNames(names) > 0 then return false end

    local classNeeded = {}
    for className, count in pairs(NS.currentClassCounts or {}) do
        classNeeded[className] = count
    end

    local matches = true
    ForEachGroupMember(function(unit, name)
        if not matches or not name or (NS.bots[strlower(name)] and not NS.bots[strlower(name)].wild) then return end
        local class = CanonicalClassOf(unit)
        if class and classNeeded[class] and classNeeded[class] > 0 then
            classNeeded[class] = classNeeded[class] - 1
        else
            matches = false
        end
    end)
    return matches
end

--- Full grouping flow: kick/remove anyone grouped who isn't in the roster
--- (named or wild-class quota), top up any wild-class quota left short,
--- then add whichever named bots from the roster aren't grouped yet,
--- check/convert-or-leave-alone, scan. Safe to re-run any time.
local function GroupRoster(onDone)
    local names = NS.currentBotNames or {}

    -- A tracked bot can be stuck occupying a stale OFFLINE group slot
    -- (server restart, crash, etc. — see ForEachGroupMember's doc comment)
    -- that MissingRosterNames below would never see as missing, so it'd
    -- never get re-added (confirmed by the user in-game: names sat as
    -- "left the game" in the party frame forever after a server restart).
    -- Rather than picking that one bot out with UninviteUnit, leave the
    -- WHOLE group cleanly and rebuild it from scratch — same "leave, wait,
    -- regroup" shape as ResetStrayGroups, just triggered automatically
    -- instead of from a button. AltBot_SavedVars.mode is untouched, so
    -- everyone comes back into whatever mode the master was already in
    -- before the restart — this only rebuilds the group, not the mode.
    if HasOfflineTrackedBots() then
        Print("Found a stale offline group slot — leaving and rebuilding the group from scratch.")
        LeaveParty()
        NS.After(NS.STRAY_GROUP_RESET_DELAY, function()
            GroupRoster(onDone)
        end)
        return
    end

    TopUpWildClasses(KickExtras())

    if #names == 0 then
        Print("No bot names saved — open the AltBot form (minimap icon) and fill in the textarea.")
        if onDone then onDone() end
        return
    end

    local missing = MissingRosterNames(names)
    if #missing == 0 then
        -- Everyone in the roster is already grouped — nothing to add, just
        -- make sure NS.bots reflects current class/level.
        ScanCurrentGroup()
        if onDone then onDone() end
        return
    end

    local firstFour, rest = {}, {}
    for i, name in ipairs(missing) do
        if i <= 4 then firstFour[#firstFour + 1] = name
        else rest[#rest + 1] = name end
    end

    Print("Adding " .. #firstFour .. " character(s): " .. table.concat(firstFour, ", "))
    SendChatMessage(".playerbots bot add " .. table.concat(firstFour, ","), "SAY")

    WaitForGroupToSettle(function()
        if GetNumRaidMembers() > 0 then
            -- Already a raid (from an earlier sync) — just add the rest of
            -- the diff, no conversion needed.
            if #rest > 0 then
                Print("Already a raid — adding remaining " .. #rest .. " character(s): "
                    .. table.concat(rest, ", "))
                SendChatMessage(".playerbots bot add " .. table.concat(rest, ","), "SAY")
            end
            ScanCurrentGroup()
            if onDone then onDone() end
        elseif GetNumPartyMembers() > 0 and PartyQualifiesForRaid() then
            ConvertToRaid()
            if #rest > 0 then
                Print("Raid formed — adding remaining " .. #rest .. " character(s): "
                    .. table.concat(rest, ", "))
                SendChatMessage(".playerbots bot add " .. table.concat(rest, ","), "SAY")
            end
            WaitForGroupToSettle(function()
                ScanCurrentGroup()
                if onDone then onDone() end
            end)
        else
            -- Doesn't qualify yet (player below RAID_CONVERT_MIN_LEVEL, or
            -- nobody in the first 4 reached it) — leave this party of (up
            -- to) 4 as it is; don't add the rest, there's no room anyway.
            if #rest > 0 then
                Print("Still a party (max 4) — need player + >=1 bot at level "
                    .. NS.RAID_CONVERT_MIN_LEVEL .. "+ to form a raid, so the remaining "
                    .. #rest .. " character(s) were not added.")
            end
            ScanCurrentGroup()
            if onDone then onDone() end
        end
    end)
end

--- Recovery for the disconnect collision: after the master's client
--- reconnects, some tracked bots can be left grouped with each other (not
--- with the master) — the server apparently doesn't cleanly regroup
--- everyone under the master on reconnect. From the master's side those
--- bots just look "missing" (MissingRosterNames doesn't see them in our
--- own group), so GroupRoster tries ".playerbots bot add <name>" for them,
--- which the server rejects per-name with "already in a group" (confirmed
--- by the user manually: logging into one of the stuck bots shows it
--- grouped with other bots, no master present). The master can't
--- UninviteUnit them either — they're not in the master's group to begin
--- with, so there's nothing to target.
---
--- Fix: whisper each tracked bot its own "leave" command (per mod-
--- playerbots' Party/Raid General Commands: "bot will leave party" —
--- works regardless of who it's currently grouped with, since the bot
--- itself executes it, not the master). Every name then reads as
--- "missing" again, so a plain GroupRoster() re-adds and (if it qualifies)
--- reconverts everyone from scratch, same as any normal grouping pass.
local function ResetStrayGroups(onDone)
    BuildRosterFromNames()   -- recomputes NS.currentBotNames from rosterText first — see its own doc comment
    local names = NS.currentBotNames or {}
    if #names == 0 then
        Print("No bot names saved — nothing to reset.")
        if onDone then onDone() end
        return
    end

    Print("Telling " .. #names .. " character(s) to leave their current group...")
    for _, name in ipairs(names) do
        SendBotCommand(name, "leave")
    end

    NS.After(NS.STRAY_GROUP_RESET_DELAY, function()
        GroupRoster(onDone)
    end)
end
NS.ResetStrayGroups = ResetStrayGroups

--- The roster's "Abandon Pet": despawns every tracked bot (".playerbots bot
--- remove", same GM command ResetStrayGroups and CleanBot's "Logout All"
--- already use) and leaves whatever's left of the group, so the master
--- ends up alone. Doesn't touch AltBot_SavedVars.rosterText — this is "put
--- them away for now", not "forget the roster"; the next Summon/Free Roam
--- click regroups the exact same names from scratch.
---
--- Sets AltBot_SavedVars.mode = MODE_SOLO (a real, persisted mode, not a
--- side flag) — this is what actually gates everything: ApplyMode treats
--- Solo as an explicit no-op (see its own early-return), the ticker skips
--- its whole OnUpdate body while EffectiveMode() == MODE_SOLO, and
--- PollBots/PollBotDetails/TrainBots' already-in-flight staggered
--- whispers bail the same way — all of which is what stopped Disband from
--- spamming "Character ... not found" into chat for names that no longer
--- exist in the world (confirmed by the user in-game). Being a real mode
--- also means it survives a disconnect/reload for free, via the same
--- AltBot_SavedVars.mode persistence every other mode already has - no
--- separate save/restore path needed.
---
--- NS.lastAppliedMode is reset too: otherwise resuming the SAME mode
--- later (e.g. was Farm, disband, click Farm again) would see
--- `mode == lastAppliedMode` and skip ApplyStrategyForMode entirely, since
--- Disband never touched lastAppliedMode itself.
local function DisbandRoster()
    BuildRosterFromNames()   -- recomputes NS.currentBotNames from rosterText first — see its own doc comment
    local names = NS.currentBotNames or {}
    if #names == 0 then
        Print("No bot names saved — nothing to disband.")
        return
    end

    Print("Disbanding " .. #names .. " character(s)...")
    AltBot_SavedVars.mode = NS.MODE_SOLO
    -- Breaks every bot's own poll loop for good (see NS.StartBotPollLoop's
    -- own doc comment on NS.pollGeneration) — per explicit user direction
    -- ("если переключение на соло, то брейк всех циклов"), rather than
    -- letting each loop keep sleeping through Solo and silently resuming.
    NS.pollGeneration = (NS.pollGeneration or 0) + 1
    NS.lastAppliedMode = nil
    if NS.RefreshActionBar then NS.RefreshActionBar() end
    -- Clears the stats board's columns immediately (see NS.RefreshPanel's
    -- own MODE_SOLO guard) — otherwise every column sat frozen showing
    -- whatever level/bags/money/XP it last had before the disband, reading
    -- as live data even though nothing polls it any more in Solo (confirmed
    -- by the user in-game).
    if NS.RefreshPanel then NS.RefreshPanel() end
    SendChatMessage(".playerbots bot remove " .. table.concat(names, ","), "SAY")

    NS.After(NS.STRAY_GROUP_RESET_DELAY, function()
        LeaveParty()
    end)
end
NS.DisbandRoster = DisbandRoster

-- ============================================================
-- Dead-bot revive check: event-driven (UNIT_HEALTH), not a timer poll — per
-- explicit user direction ("если через событие то еще лучше"), a 3.3.5
-- UNIT_HEALTH fires on every health change for the unit token in its own
-- event arg, so watching it catches a death the instant it happens instead
-- of waiting up to NS.REVIVE_INTERVAL. Only acts on tracked, grouped bots
-- (UnitIsDeadOrGhost needs a live unit token) — an ungrouped tracked bot
-- just isn't checked until GroupRoster groups it. In practice only ever
-- does anything in Farm/Quest mode, since Solo has no grouped bots at all.
-- ============================================================
--- Checks one unit (or, with no argument, every currently grouped tracked
--- bot) for a dead/ghost <-> alive transition and reacts to it. Whispers
--- "summon" every time it's seen dead (UNIT_HEALTH can fire repeatedly while
--- already dead — e.g. a ghost's health staying at 0 across other events —
--- so this isn't gated to "only once"), and "rpg status wander random"
--- (Farm mode only) exactly once, the instant it's seen alive again after
--- having been dead.
NS.CheckReviveBots = function(onlyUnit)
    local function checkOne(unit, name)
        if not name then return end
        local entry = NS.bots[strlower(name)]
        if not entry then return end
        if UnitIsDeadOrGhost(unit) then
            entry.wasDead = true
            -- A summon revives a dead bot, and the bot confirms it with
            -- "Я снова жив!" (seen in-game); alive-and-tradeable (verify)
            -- also counts. No answer within 2s -> resent, up to 3 more
            -- times. key keeps this 5s check from stacking a second summon
            -- chain while one is still running (it used to just re-send
            -- "summon" on every tick); if it all fails, the next tick tries
            -- again.
            NS.SendBotChain(entry.name, {
                { cmd = "summon", critical = true, retries = 3,
                  wait = "reply", timeout = NS.STEP_DELAY, reply = "Я снова жив!",
                  verify = function() return NS.NearAndWarm(entry.name) end },
            }, { key = "revive" })
        elseif entry.wasDead then
            -- Just came back from dead/ghost (this check just saw it alive
            -- for the first time since dying) — Farm mode only, per explicit
            -- user direction ("так же для сброса сумок и смерти, если мы в
            -- фарм режиме, то в конце rpg status wander random"): the bot's
            -- old rpg-status state is stale after a death/summon round trip,
            -- so re-explore rather than assume "go grind" is still valid.
            entry.wasDead = false
            entry.trackedKind = nil   -- dying drops the tracking: cast it again
            NS.ApplyTracking(entry)
            if AltBot_SavedVars.mode == NS.MODE_FARM then
                -- The bot's been sitting summoned at the master this whole
                -- time it was dead (see the UnitIsDeadOrGhost branch above),
                -- so it's right there at a vendor-reachable spot — sell off
                -- junk before it wanders back out. 
                SendBotCommand(entry.name, NS.SellCommand())
                SendBotCommand(entry.name, "rpg status wander random")
            end
        end
    end

    if onlyUnit then
        checkOne(onlyUnit, UnitName(onlyUnit))
    else
        ForEachGroupMember(checkOne)
    end
end

local reviveWatcher = CreateFrame("Frame")
reviveWatcher:RegisterEvent("UNIT_HEALTH")
reviveWatcher:SetScript("OnEvent", function(self, event, unit)
    NS.CheckReviveBots(unit)
end)

-- ============================================================
-- Polling: each tracked bot runs its OWN independent, self-scheduling loop
-- — not a single shared "poll everyone, compute a stagger step" pass. Per
-- explicit user direction ("можно же для каждого бота запустить бесконечный
-- цикл сдвинув его старт при запуске аддона, в котором мы делаем все, что
-- нам нужно с конкретным ботом и спим оставшееся от 30 секунд время"):
-- replaces the earlier centralized PollBots design, which recomputed a
-- shared NS.STAGGER_DELAY from a roster-wide bot count every pass and
-- staggered every bot's slot off of that one shared timeline — a design
-- that kept producing the same class of bug in different shapes (the last
-- bot's slot landing exactly on the next pass boundary; a bot's own
-- STATS_TIMEOUT firing before its staggered send even went out; a stats
-- reply arriving a hair late under real server-AI load getting silently
-- dropped because the shared flag had already been force-cleared) because
-- a bot's own timing was never actually independent of every other bot's.
--
-- NS.StartBotPollLoop(key), called once per bot (when it's first added to
-- NS.bots in BuildRosterFromNames) with a staggered initial delay (see
-- NS.STAGGER_DELAY's own comment) so the whole roster doesn't whisper in
-- visible lockstep, is a single self-contained recursive NS.After chain per
-- bot: wait -> (if eligible)
-- send "stats" (+ "rpg status" in Farm mode) -> wait for a reply or give up
-- after NS.STATS_TIMEOUT -> sleep whatever's left of NS.POLL_INTERVAL since
-- this cycle started -> repeat. A bot's own cycle never touches or depends
-- on any other bot's state, so one bot being slow/stuck can't push another
-- bot's timing around.
-- ============================================================
-- Recomputed by BuildRosterFromNames as NS.POLL_INTERVAL / (roster size) —
-- not a flat constant — so a roster of any size has its bots' initial poll
-- starts spread across the FULL 30s interval, not bunched into a fraction
-- of a second at the front (confirmed by the user in-game: a fixed small
-- step made every bot's first poll look simultaneous). TrainBots also reads
-- this same field for its own stagger, so it inherits whatever the current
-- roster size last computed.
NS.STAGGER_DELAY = 0.4

local botPollLoopStarted = {}   -- lower(name) -> true once NS.StartBotPollLoop has been called for it
local botPollLoopStaggerCount = 0   -- how many bots have had a loop started so far, for the initial stagger offset

-- Bumped every time the mode switches TO Solo (see DisbandRoster) — a
-- running cycle() captures NS.pollGeneration at the start of each of its own
-- iterations and simply stops rescheduling itself if the generation has
-- moved on, instead of sleeping through Solo and silently resuming 30s
-- later. Per explicit user direction ("если переключение на соло, то брейк
-- всех циклов"). There's no API to cancel an already-scheduled NS.After
-- timer, so this is how every bot's loop actually halts rather than firing
-- one more time: cycle() always checks the generation it captured against
-- the current one before doing any work or rescheduling.
NS.pollGeneration = 0

--- Clears every bot's "loop already started" record so the NEXT
--- NS.StartBotPollLoop(key) call for each of them actually starts a fresh
--- cycle, re-staggered from scratch — needed because DisbandRoster's
--- generation bump permanently kills every running cycle (see
--- NS.pollGeneration's own doc comment), so simply calling
--- NS.StartBotPollLoop again for an already-known bot would otherwise no-op
--- forever (botPollLoopStarted[key] already true from its first-ever start).
--- Called from NS.ApplyMode whenever the mode is actually leaving Solo.
NS.RestartAllBotPollLoops = function()
    botPollLoopStarted = {}
    botPollLoopStaggerCount = 0
end

--- Starts `key`'s own independent poll loop (safe to call more than once —
--- only the first call for a given key actually starts anything). The first
--- call in the whole session for each NEW bot staggers its initial start by
--- NS.STAGGER_DELAY * (how many other loops already started), so a roster
--- added all at once doesn't have every bot's first "stats" land in the same
--- frame; after that, each bot's cycle paces itself entirely off its own
--- elapsed time, never off any shared schedule.
NS.botPollEpoch = {}   -- lower(name) -> id of the bot's current poll loop

--- Ends a bot's poll loop (it was dropped from the roster) so that adding the bot
--- back starts a fresh one. Before, the loop quietly died with the dropped entry
--- but "already started" stayed set - a bot re-added later was never polled again.
NS.StopBotPollLoop = function(key)
    botPollLoopStarted[key] = nil
    NS.botPollEpoch[key] = (NS.botPollEpoch[key] or 0) + 1
end

NS.StartBotPollLoop = function(key)
    if botPollLoopStarted[key] then return end
    botPollLoopStarted[key] = true
    NS.botPollEpoch[key] = (NS.botPollEpoch[key] or 0) + 1
    local epoch = NS.botPollEpoch[key]   -- a loop belongs to its epoch; a newer start for the same bot kills it
    local initialDelay = botPollLoopStaggerCount * NS.STAGGER_DELAY
    botPollLoopStaggerCount = botPollLoopStaggerCount + 1
    -- The bot's own fixed phase in absolute time — set once, right before
    -- the very first cycle fires, and advanced by exactly NS.POLL_INTERVAL
    -- every time a cycle schedules its successor, REGARDLESS of how long
    -- that cycle's own send/reply/retry actually took. Per explicit user
    -- direction after seeing it happen in-game ("опять в одну миллисекунду
    -- идут запросы ко всем ботам"): scheduling the next cycle as
    -- "NS.POLL_INTERVAL minus however long THIS cycle took" (the earlier
    -- version) let every bot's phase drift toward whatever the server's
    -- typical reply latency was, since a fast reply (the common case) left
    -- almost the full 30s to the next schedule call regardless of each
    -- bot's original stagger offset — after a few cycles, bots that started
    -- stagger-spread apart all converged back onto roughly the same moment.
    -- Anchoring to a fixed, ever-advancing absolute timestamp instead of
    -- "time elapsed since this cycle started" means the original stagger
    -- offset is permanent, not just a one-time head start.
    local nextFireTime = GetTime() + initialDelay

    local function cycle(generation)
        local entry = NS.bots[key]
        if not entry then return end   -- no longer tracked - this bot's loop simply stops
        if generation ~= NS.pollGeneration then return end   -- Solo was entered - this loop is dead for good
        if NS.botPollEpoch[key] ~= epoch then return end     -- superseded by a newer loop for the same bot

        -- THE NEXT CYCLE IS SCHEDULED FIRST, on its fixed phase, before anything
        -- else - a cycle is never skipped, never delayed and never depends on a
        -- reply, a flag or a chain being in some state (per explicit user
        -- direction: "цикл не должен пропускаться никогда"). Whatever this cycle
        -- starts below has until that moment to finish.
        nextFireTime = nextFireTime + NS.POLL_INTERVAL
        local delay = nextFireTime - GetTime()
        if delay < 0 then delay = 0 end   -- (phase stays anchored; it just catches up)
        NS.After(delay, function() cycle(generation) end)

        -- A bot's work has its own SLOT inside the cycle: the stagger step between
        -- one bot's start and the next one's (POLL_INTERVAL / roster size). The
        -- tick indicator lights strictly when the slot opens and goes out when the
        -- reply is in OR the slot is over - work that doesn't fit is dropped, not
        -- carried over (per explicit user direction).
        local slotLen = math.max(1.5, NS.STAGGER_DELAY or NS.POLL_INTERVAL)
        local slotEnd = GetTime() + slotLen
        local function timeLeftInSlot()
            return slotEnd - GetTime()
        end

        -- A new cycle KILLS everything the previous one left unfinished: its
        -- pending request flags and reply callbacks, its retry timers (they
        -- check the cycle id below), a half-finished rpg-status follow-up, and
        -- a Farm "vendor" step nothing is working on any more (a cancelled
        -- chain used to leave it stuck forever, and with it the bot's poll).
        entry.pollCycleId = (entry.pollCycleId or 0) + 1
        local cycleId = entry.pollCycleId
        local function alive() return entry.pollCycleId == cycleId end
        entry.awaitingStats = false
        entry.awaitingRpgStatus = false
        entry.awaitingRpgAction = nil
        NS.pollCycleCallbacks[key] = {}
        local chains = NS.botChains[key]
        if entry.step ~= "idle" and not (chains and chains.running) then
            entry.step = "idle"
            if NS.active == key then NS.active = nil end
        end

        -- Only whisper a bot actually reachable as a group unit right now -
        -- a tracked name that hasn't (yet, or successfully) joined the group
        -- just bounces the whisper back as "Character ... not found" with
        -- nothing to poll (confirmed by the user in-game: after a genuine
        -- disconnect/relogin, a bot can still be catching up to the group
        -- when this fires). The cycle still happens - it just has nobody to ask.
        local grouped = false
        ForEachGroupMember(function(_, name)
            if name and strlower(name) == key then grouped = true end
        end)
        if not grouped then
            NS.ClearTickIndicator(key)   -- nobody to ask: no stale light either
            return
        end

        NS.SetTickIndicator(key)   -- strictly at the slot's start
        NS.After(slotLen, function()
            if not alive() then return end
            -- The slot is over: abandon whatever is still unanswered and put the light out.
            entry.awaitingStats = false
            entry.awaitingRpgStatus = false
            NS.ClearTickIndicator(key)
        end)

        -- A bot parked via the board's top row (entry.farmHeld) still gets
        -- "stats" polled, but no "rpg status" - nothing to grind/wander over.
        local farmMode = AltBot_SavedVars.mode == NS.MODE_FARM and not entry.farmHeld

        -- Sends a request (stats or rpg status); it's re-sent every STATS_TIMEOUT
        -- while there's still more than that left of the slot (so only with a
        -- big slot - a small roster), and dropped when the slot ends.
        local function sendWithRetry(command, awaitingField)
            local function attempt()
                if not alive() or not entry[awaitingField] then return end
                SendBotCommand(entry.name, command)
                NS.After(NS.STATS_TIMEOUT, function()
                    if not alive() or not entry[awaitingField] then return end   -- killed, or a reply already landed
                    if timeLeftInSlot() > NS.STATS_TIMEOUT then
                        attempt()
                    end
                end)
            end
            attempt()
        end

        entry.awaitingStats = true
        NS.pollCycleCallbacks[key].onStats = function()
            if alive() then entry.awaitingStats = false end
        end
        sendWithRetry("stats", "awaitingStats")

        if farmMode then
            entry.awaitingRpgStatus = true
            NS.pollCycleCallbacks[key].onRpgStatus = function()
                if alive() then entry.awaitingRpgStatus = false end
            end
            sendWithRetry("rpg status", "awaitingRpgStatus")
        end

        -- "items" too, fire-and-forget (the reply is collected and merged by
        -- the bags-cache collector): keeps the cache current and feeds the
        -- ammo/poison checks (NS.CheckBotSupplies).
        if NS.PollBotItems then NS.PollBotItems(entry.name) end

        if NS.RefreshPanel then NS.RefreshPanel() end
    end

    NS.After(initialDelay, function() cycle(NS.pollGeneration) end)
end

-- lower(name) -> { onStats = fn|nil, onRpgStatus = fn|nil } — the CURRENT
-- poll cycle's own completion callbacks for this bot, set fresh by
-- NS.StartBotPollLoop's cycle() every time it sends, and called by the
-- whisper watchers below the instant a real reply lands (not by a shared
-- timeout loop) so a cycle advances as soon as it genuinely can, and the
-- STATS_TIMEOUT path above is only ever the lost-reply fallback.
NS.pollCycleCallbacks = {}

-- ============================================================
-- Trainer visits: whisper "trainer" to every tracked bot. No more Study
-- mode/button — there's no separate mode for this at all any more, it just
-- fires whenever the MASTER opens a real trainer's window (see the
-- TRAINER_UPDATE watcher below TrainBots), on whatever mode happens to be
-- active (skipped entirely in Solo — see that watcher's own guard). The
-- server does all the deciding itself once whispered — no client-side
-- price/money check, no separate "trainer learn" command. Confirmed live
-- (user tested it): one plain "trainer" whisper makes the bot learn
-- everything it currently has gold for and reports the rest as
-- unaffordable, e.g.:
--   --- Can learn from Magis Sparkmantle ---
--   [Fire Blast]95c - learned
--   [Conjure Water]95c - too expensive
--   Total cost: 1s 90c
-- Bots that can't currently afford everything just catch up the next time
-- the master visits a trainer. Each learned/too-expensive line is printed
-- straight to chat (see NS.FinalizeTrainerResult below) — nothing cached,
-- no panel/tooltip display, per explicit user direction.
-- ============================================================
local function TrainBots()
    -- Same "only whisper bots actually grouped right now" guard every other
    -- background whisper loop in this file uses (see NS.StartBotPollLoop's
    -- own comment for why).
    local grouped = {}
    ForEachGroupMember(function(_, name)
        if name then grouped[strlower(name)] = true end
    end)

    local i = 0
    for _, key in ipairs(NS.rosterOrder) do
        local entry = NS.bots[key]
        if entry and grouped[key] and entry.step == "idle" and not entry.awaitingTrainer then
            entry.awaitingTrainer = true
            entry.trainerTimer    = 0
            entry.trainerLines    = {}
            NS.After(i * NS.STAGGER_DELAY, function()
                if NS.EffectiveMode() == NS.MODE_SOLO then return end
                if entry.step == "idle" and entry.awaitingTrainer then
                    SendBotCommand(entry.name, "trainer")
                end
            end)
            i = i + 1
        end
    end
end

--- Fires TrainBots when the MASTER actually opens a real trainer's window
--- — TRAINER_UPDATE, confirmed against the real 3.3.5 client source
--- (Interface/AddOns/Blizzard_TrainerUI/Blizzard_TrainerUI.lua), fires
--- only once the trainer list is populated after interacting with a
--- genuine trainer NPC, never on a bare target change.
---
--- Originally this used PLAYER_TARGET_CHANGED + "is the target an NPC"
--- (no reliable client-side way to tell "specifically a trainer" apart
--- otherwise) — but that fired for ANY NPC the master targeted, in ANY
--- non-Solo mode, so out grinding in Farm mode a stray target could
--- silently trigger the whole roster's "trainer" whisper, and any tracked
--- bot that happened to be standing near an actual trainer at that moment
--- would spend its gold with no visible cause (confirmed by the user
--- in-game: "боты тратят деньги, не могу понять на что"). TRAINER_UPDATE
--- has no such false positives — it only fires from the master's own
--- deliberate interaction with a real trainer.
---
--- Debounced by NS.TRAINER_TARGET_DEBOUNCE since TRAINER_UPDATE can fire
--- more than once while the same window stays open (e.g. as sections load
--- in). Skipped entirely in Solo mode (see NS.MODE_SOLO) - nothing runs in
--- the background while the roster's despawned.
local lastTrainerTargetTime = 0
local trainerTargetWatcher = CreateFrame("Frame")
trainerTargetWatcher:RegisterEvent("TRAINER_UPDATE")
trainerTargetWatcher:SetScript("OnEvent", function()
    if NS.EffectiveMode() == NS.MODE_SOLO then return end
    local now = GetTime()
    if now - lastTrainerTargetTime < NS.TRAINER_TARGET_DEBOUNCE then return end
    lastTrainerTargetTime = now
    TrainBots()
end)

-- When the master opens a vendor window (MERCHANT_SHOW) every tracked bot gets the sell command
-- ("s *" or "s vendor", see NS.SellCommand) - per explicit user direction, caught the same way as
-- the trainer window above. The bots standing near that vendor sell; the others have nobody to sell
-- to. Debounced, skipped in Solo, spaced a little so the whispers do not go out in one burst.
-- Buying: in Quest mode, with a tracked bot in the target, an item clicked at the vendor is bought FOR THAT
-- BOT ("b <item link>" whispered to it, once per unit bought) instead of for the master - per explicit user
-- direction. Done by wrapping the client's BuyMerchantItem; with no bot targeted (or in another mode) the
-- purchase is the ordinary one.
NS.originalBuyMerchantItem = BuyMerchantItem
BuyMerchantItem = function(index, quantity)
    if NS.EffectiveMode() == NS.MODE_QUEST and UnitExists("target") then
        local name = UnitName("target")
        local entry = name and NS.bots[strlower(name)]
        local link = GetMerchantItemLink(index)
        if entry and link then
            local units = math.min(math.max(tonumber(quantity) or 1, 1), 20)
            for i = 1, units do
                NS.After((i - 1) * 0.3, function() SendBotCommand(entry.name, "b " .. link) end)
            end
            -- A vendor sells in LOTS (arrows: 200 at a time): the listed price is the price of one lot of
            -- `lot` items, so `units` purchases bring units * lot items for units * price.
            local _, _, price, lot = GetMerchantItemInfo(index)
            lot = math.max(lot or 1, 1)
            NS.AddBagsItemOptimistically(entry.name, link, units * lot, (price or 0) * units)
            PlaySound("LOOT_WINDOW_COIN_SOUND")   -- the clink of coins
            PlaySoundFile("Sound\\Interface\\LootCoinLarge.wav")
            -- the real free-slot count and gold come from the bot's own "stats" a moment after the purchase
            if not entry.statsAfterBuy then
                entry.statsAfterBuy = true
                NS.After(units * 0.3 + 2, function()
                    entry.statsAfterBuy = nil
                    SendBotCommand(entry.name, "stats")
                end)
            end
            Print("bought for " .. entry.name .. ": " .. link .. (units > 1 and (" x" .. units) or ""), "inventory")
            return
        end
    end
    return NS.originalBuyMerchantItem(index, quantity)
end

NS.MERCHANT_SELL_DEBOUNCE = 3.0
NS.lastMerchantSell = 0
NS.merchantWatcher = CreateFrame("Frame")
NS.merchantWatcher:RegisterEvent("MERCHANT_SHOW")
NS.merchantWatcher:SetScript("OnEvent", function()
    if NS.EffectiveMode() == NS.MODE_SOLO then return end
    local now = GetTime()
    if now - NS.lastMerchantSell < NS.MERCHANT_SELL_DEBOUNCE then return end
    NS.lastMerchantSell = now
    local i = 0
    for _, key in ipairs(NS.rosterOrder) do
        local entry = NS.bots[key]
        if entry then
            NS.After(i * 0.3, function() SendBotCommand(entry.name, NS.SellCommand()) end)
            i = i + 1
        end
    end
end)

--- Parses the collected "trainer" reply lines and prints each learned/
--- too-expensive skill straight to chat via the same Print(entry.name ..
--- ": ...") style the Farm unload chain already uses for "bags full"/
--- "unload complete" — nothing else: no panel/tooltip display, no cached
--- state, per explicit user direction ("не нужно ничего кроме чата от
--- AltBot"). If no skill lines were found at all (bot has nothing left to
--- learn, so the trainer sent no reply, or just the header/total with no
--- actual skill entries), prints a single "nothing to learn" line instead —
--- otherwise a silent bot looks indistinguishable from one whose reply was
--- lost/never sent. Called on collection finalize (silence timeout — see
--- the main ticker); never gates re-sending "trainer" on the next pass.
NS.FinalizeTrainerResult = function(key, entry)
    local any = false
    for _, line in ipairs(entry.trainerLines or {}) do
        local skillName, cost, status = line:match("^%[(.-)%](%S+)%s*%-%s*(.+)$")
        if skillName then
            any = true
            Print(entry.name .. ": " .. skillName .. " " .. cost .. " - " .. status)
        end
    end
    if not any then
        Print(entry.name .. ": nothing to learn")
    end
end

-- ============================================================
-- Farm mode bag-full chain (one bot at a time — see the RPG watcher further
-- below for the wander/grind side of Farm mode): "summon" (teleport to the
-- master — see the file header's Farm-mode-doesn't-free-the-master note:
-- the master has to stay with the roster for revive/summon anyway, so
-- summoning to the master is no extra cost) -> "s *" -> "rpg status go
-- grind" to resume grinding. No re-check via "stats" afterward (per
-- explicit user direction: "только summon -> s * -> rpg status go grind,
-- без проверок очистил он сумки или нет, если не очистил, то его штатная
-- проверка сумок опять дернет") — if one vendor visit didn't fully clear
-- the bags (stack limits, non-vendor trash), the normal idle "stats" poll
-- (see NS.StartBotPollLoop) will notice bagFree == 0 again on its own next
-- cycle and re-enqueue this same chain, so a dedicated re-check here would
-- just be duplicating that.
--
-- Previously used "rpg status go camp" instead of summoning to the master,
-- on the theory that bots reaching their own camp let the master roam
-- freely — reverted per explicit user direction ("идея с camp для сброса
-- сумок не удачная, слишком долго бот пробирается в camp, а мастера мы
-- все-равно не освобождаем, он нужен для суммона при смерти бота, а мрут
-- боты часто"): the master never actually gets freed (revive/summon-on-
-- death still needs it nearby), so camp's travel time was pure overhead
-- with no real benefit. No "botAI reset" step either — Farm's rpg status
-- strategy survives a summon fine on its own. No invite/uninvite bracket —
-- everyone stays grouped permanently.
-- ============================================================
local function StartNextInQueue()
    if NS.active then return end
    local key = table.remove(NS.queue, 1)
    if not key then return end
    local entry = NS.bots[key]
    if not entry then StartNextInQueue(); return end

    NS.active = key
    entry.step = "vendor"
    entry.stepTimer = 0
    NS.NoteUnloadTry(entry)
    Print(entry.name .. ": bags full, summoning to sell", "farm")
    -- summon and sell get no confirmation from the bot, so each just gets a
    -- settle delay (see the chain block comment near SendBotCommand);
    -- abortIf drops the chain if something else moved the bot off "vendor".
    -- Sell, then an extra "stats" only if the bot actually sold something
    -- (see NS.SellAndRecheckSteps) so the board's bag count catches up.
    local sellSteps = NS.SellAndRecheckSteps(NS.STEP_DELAY, entry)
    NS.SendBotChain(entry.name, {
        NS.SummonStep(entry),   -- confirmed by being tradeable, retried if not
        sellSteps[1],
        sellSteps[2],
        -- "wander random" (not "go grind" directly) — same reasoning as
        -- the summon/no-recognized-status branch of the rpg-status
        -- dispatch above: the bot just teleported back from the vendor,
        -- so it needs to re-explore before a grind position is valid
        -- again, per explicit user direction ("так же для сброса сумок
        -- и смерти, если мы в фарм режиме, то в конце rpg status wander
        -- random"). Skipped for one parked via the board's top row.
        { cmd = function()
            if entry.farmHeld then return nil end
            return "rpg status wander random"
        end },
    }, {
        abortIf = function() return entry.step ~= "vendor" end,   -- chain moved on/cancelled
        onFail = function()
            -- The bot never became tradeable after the summon retries —
            -- give up on this unload, free the slot for the next bot; the
            -- normal "stats" poll re-enqueues it if the bags are still full.
            Print(entry.name .. ": summon failed, skipping unload", "farm")
            entry.step = "idle"
            NS.active = nil
            StartNextInQueue()
            if NS.RefreshPanel then NS.RefreshPanel() end
        end,
        onDone = function()
            Print(entry.name .. ": unload complete, resuming grind", "farm")
            -- bagFree/bagTotal are deliberately left as they were (not reset
            -- to nil -> "?") — the board keeps showing e.g. 0/40 until the
            -- next "stats" reply replaces it, so the bags-window click target
            -- always has a real slot count behind it (per explicit user
            -- direction).
            entry.step     = "idle"
            NS.active = nil
            StartNextInQueue()
            if NS.RefreshPanel then NS.RefreshPanel() end
        end,
    })
    if NS.RefreshPanel then NS.RefreshPanel() end
end

-- Per explicit user direction: if an unload trip freed no space, calling the bot again and again
-- is useless - what it carries is not going to be sold. A bot gets NS.UNLOAD_MAX_TRIES trips; after
-- that it is left alone until a "stats" reply shows MORE free slots than before the first trip.
NS.UNLOAD_MAX_TRIES = 2
NS.UnloadAllowed = function(entry)
    return (entry.unloadTries or 0) < NS.UNLOAD_MAX_TRIES
end
NS.NoteUnloadTry = function(entry)
    entry.unloadTries = (entry.unloadTries or 0) + 1
    if entry.unloadTries == 1 then entry.unloadBase = entry.lastStatsFree or 0 end
    if entry.unloadTries >= NS.UNLOAD_MAX_TRIES then
        Print(entry.name .. ": the unload freed no space, not calling it to sell again until space appears", "farm")
    end
end

local function EnqueueForUnload(key, entry)
    if entry.step ~= "idle" then return end   -- already queued/running
    if not NS.UnloadAllowed(entry) then return end
    for _, k in ipairs(NS.queue) do
        if k == key then return end            -- already queued
    end
    entry.step = "queued"
    NS.queue[#NS.queue + 1] = key
    StartNextInQueue()
end

-- ============================================================
-- Quest mode's bag reaction: no reset/summon/strategy juggling at all — just
-- whisper "s *" (sell everything the vendor buys) to every tracked bot once
-- whenever any tracked bot reports 0 free bag slots, on the theory that
-- quest bots already run alongside the player via mod-playerbots' own
-- follow behavior, so whichever one(s) happen to be at a vendor with the
-- player will unload right then. Individual whispers (SendBotCommand), not
-- a group-chat broadcast — every automated command in this file goes
-- per-bot over whisper, per explicit user direction ("все только через
-- шепот").
-- ============================================================
local questVendorSpamPending = false

local function QuestModeSpamVendor()
    if questVendorSpamPending then return end
    questVendorSpamPending = true
    local i = 0
    for _, key in ipairs(NS.rosterOrder) do
        local entry = NS.bots[key]
        if entry and NS.UnloadAllowed(entry) then
            NS.NoteUnloadTry(entry)
            NS.After(i * NS.STAGGER_DELAY, function()
                SendBotCommand(entry.name, NS.SellCommand())
            end)
            i = i + 1
        end
    end
    NS.After(NS.STEP_DELAY, function() questVendorSpamPending = false end)
end

--- Dispatches a tracked bot's bagFree == 0 report to whatever the active
--- mode wants done about it. Farm mode runs the full unload chain; Quest
--- mode just spams the vendor-sell raid command; Solo never gets here at
--- all (no bots grouped to report a full bag).
NS.OnBagsFull = function(key, entry)
    -- No fallback to MODE_QUEST — see ApplyMode's fresh-install guard. In
    -- practice this is unreachable pre-first-click anyway (NS.rosterOrder
    -- stays empty until BuildRosterFromNames runs, which ApplyMode gates),
    -- but staying nil-safe here avoids silently defaulting to Quest bag
    -- handling for an unconfigured roster if that ever changes.
    local mode = AltBot_SavedVars.mode
    if not mode then return end
    if mode == NS.MODE_FARM then
        EnqueueForUnload(key, entry)
    elseif mode == NS.MODE_QUEST then
        QuestModeSpamVendor()
    end
    -- MODE_SOLO: unreachable in practice (OnBagsFull only fires for a
    -- grouped bot, and Solo has none), but no bag reaction either way.
end

-- ============================================================
-- Mode application: no more start/stop — the textarea + the active radio
-- button ARE the state. NS.ApplyMode re-syncs the roster/grouping/polling to
-- whatever's currently saved; called once at login/reload and again any
-- time the form closes (textarea and/or mode may have changed — there's no
-- separate Save button, closing the form IS saving, per explicit user
-- direction).
--
-- Class-token wild-bot quotas (NS.currentClassCounts) ARE part of
-- ApplyMode via GroupRoster -> KickExtras/TopUpWildClasses — they're a
-- standing requirement re-checked on every sync (login/reload/form-close),
-- not a one-shot action. See ParseRosterText's doc comment for the full
-- spec and the KickExtras/TopUpWildClasses pair above for the enforcement.
-- ============================================================

--- onFail callback for a mode-switch chain: says which bot's critical step
--- never got confirmed even after its retries.
local function ChainFailPrinter(entry)
    return function(failedCmd)
        Print(entry.name .. ": '" .. tostring(failedCmd) .. "' not confirmed after retries", NS.ChainCategory(failedCmd))
    end
end

--- Makes every tracked bot's strategy match `mode`:
---   Quest -> "reset botAI" (default AI, no farming strategy). If the
---     PREVIOUS mode was Farm specifically, also whispers "summon" to every
---     tracked bot — bots reset out of Farm's grind/rpg strategy may be
---     scattered from farming, so pull them back in; a Quest login/re-sync
---     that wasn't coming from Farm has no reason to summon.
---   Farm  -> NS.RESTORE_STRATEGY ("nc +new rpg,-follow").
---   Study -> untouched, whatever strategy each bot already has stays as-is
---     (per explicit user direction — Study never sends a strategy command).
--- Called from ApplyMode whenever the saved mode differs from the last mode
--- actually applied (NS.lastAppliedMode) — so it fires once per real
--- transition (button click, or the saved mode having changed since the
--- last sync) and not on every login/reload/form-close re-sync that leaves
--- the mode unchanged. Individual whispers throughout, not a group-chat
--- broadcast — per explicit user direction ("все только через шепот").
local function ApplyStrategyForMode(mode, previousMode)
    -- A real mode change ends every "parked" Farm bot (entry.farmHeld) — the
    -- strategy commands below apply to the whole roster anyway. NOT on a
    -- fresh load into Farm (previousMode == nil, i.e. /reload or login):
    -- parked bots stay parked then, see the Farm branch below.
    local keepHeld = mode == NS.MODE_FARM and previousMode == nil
    if not keepHeld then
        for _, entry in pairs(NS.bots) do NS.SetFarmHeld(entry, false) end
        NS.CharVars().farmHeld = nil   -- also drops marks of bots no longer on the roster
    end

    if mode == NS.MODE_QUEST then
        if previousMode == NS.MODE_FARM then
            -- Per bot: "reset botAI", a NS.STEP_DELAY settle gap (summoning
            -- immediately after reset doesn't reliably teleport every bot;
            -- some walk instead of porting, or don't move at all, because
            -- the reset hasn't settled server-side yet), then a summon that
            -- is retried until the bot is actually tradeable. Any Farm-side
            -- chain still running for the bot (unload, parking) is dropped
            -- first, and a half-done unload's "vendor" step is cleared so
            -- the bot's polling isn't left skipped.
            for _, key in ipairs(NS.rosterOrder) do
                local entry = NS.bots[key]
                if entry then
                    NS.CancelBotChains(entry.name)
                    entry.step = "idle"
                    local steps = {
                        NS.ResetStep(),   -- its reply doubles as the settle gap before summoning
                        NS.SummonStep(entry),
                    }
                    for _, st in ipairs(NS.SavedStanceSteps()) do steps[#steps + 1] = st end
                    NS.SendBotChain(entry.name, steps, { onFail = ChainFailPrinter(entry) })
                end
            end
            Print("Quest mode: strategy reset to default, summoning tracked bots back after leaving Farm mode.")
        else
            for _, key in ipairs(NS.rosterOrder) do
                local entry = NS.bots[key]
                if entry then
                    NS.CancelBotChains(entry.name)
                    local steps = { NS.ResetStep() }
                    for _, st in ipairs(NS.SavedStanceSteps()) do steps[#steps + 1] = st end
                    NS.SendBotChain(entry.name, steps, { onFail = ChainFailPrinter(entry) })
                end
            end
            Print("Quest mode: strategy reset to default on all tracked bots.")
        end
    elseif mode == NS.MODE_FARM then
        for _, key in ipairs(NS.rosterOrder) do
            local entry = NS.bots[key]
            if entry and entry.farmHeld then
                -- Restored parked bot (after /reload): keeps its reset
                -- strategy, but must still be right here at the master —
                -- re-summon it (verified) if it isn't; if that never lands,
                -- release the mark so the bot goes back to normal farming.
                NS.CancelBotChains(entry.name)
                NS.SendBotChain(entry.name, { NS.SummonStep(entry) }, {
                    onFail = function()
                        Print(entry.name .. ": summon not confirmed, no longer parked", "farm")
                        NS.SetFarmHeld(entry, false)
                        NS.SendBotChain(entry.name, { NS.FarmStrategyStep() },
                            { onFail = ChainFailPrinter(entry) })
                        if NS.RefreshPanel then NS.RefreshPanel() end
                    end,
                })
            elseif entry then
                NS.CancelBotChains(entry.name)
                NS.SendBotChain(entry.name, { NS.FarmStrategyStep() },
                    { onFail = ChainFailPrinter(entry) })
            end
        end
        Print("Farm mode: farming strategy set on all tracked bots.")
    end
    -- Never actually called with mode == MODE_SOLO — ApplyMode returns
    -- before reaching this (see its own early-return).
end

--- Re-syncs tracked state to whatever's currently saved (textarea + mode).
--- Safe to call any time — on login/reload and on every form close.
---
--- Grouping (".playerbots bot add" for any tracked name missing from the
--- world/group, forming a party and converting to a raid once it qualifies)
--- happens for ALL modes, not just Farm — the mode does not gate whether
--- bots get summoned into the world, only what happens to them once grouped.
--- Strategy (ApplyStrategyForMode) only fires on an actual mode change
--- versus NS.lastAppliedMode, so re-syncing with the same mode never re-spams
--- reset/strategy commands.
-- Fresh-install guard: on a brand-new install/character AltBot_SavedVars.mode
-- is nil (no default mode auto-selected — see file header's first-run flow),
-- meaning "not configured yet". ApplyMode no-ops entirely in that state: no
-- grouping, no strategy, nothing — the addon stays fully inert until the
-- user fills the textarea and clicks a mode button for the first time, which
-- both saves the roster AND sets AltBot_SavedVars.mode, so this guard only
-- ever blocks the pre-first-click state, never a real subsequent sync.
--- The mode line ("<Mode> mode, N bot(s)."): shown always - at the start and at every mode switch, per
--- explicit user direction (it says which mode the addon is in now).
NS.PrintModeLine = function(text)
    Print(text, "always")
end

NS.lastAppliedMode = nil
NS.ApplyMode = function(onDone, silent)
    AltBot_SavedVars = AltBot_SavedVars or {}
    local mode = NS.EffectiveMode()
    if not mode then
        -- Not configured yet (first run): reads as Solo with nobody tracked.
        NS.PrintModeLine("Solo mode, 0 bot(s).")
        return
    end

    -- Solo is an explicit no-op mode (see NS.MODE_SOLO/DisbandRoster) -
    -- unlike the nil case above ("not configured yet"), this means "roster
    -- was deliberately put away", so nothing here should regroup/restrategy
    -- it back. Resuming happens only via an explicit Summon/Free Roam
    -- click (or Save while one of those is already the saved mode), which
    -- sets AltBot_SavedVars.mode away from MODE_SOLO before calling this.
    if mode == NS.MODE_SOLO then
        NS.PrintModeLine("Solo mode, 0 bot(s).")
        return
    end

    -- Actually leaving Solo (not just a routine re-sync in an already-active
    -- mode) — every bot's own poll loop was permanently killed by
    -- DisbandRoster's generation bump, so it needs a fresh start, not just
    -- BuildRosterFromNames' usual no-op call for already-known bots.
    if NS.lastAppliedMode == NS.MODE_SOLO then
        NS.RestartAllBotPollLoops()
    end

    NS.queue  = {}
    NS.active = nil

    BuildRosterFromNames()

    -- The board stays hidden until the whole raid-forming pass is done, per explicit
    -- user direction ("табло мы показываем только после того как вся процедура
    -- создания рейда и включения туда ботов завершилась").
    NS.boardReady = false
    GroupRoster(function()
        NS.boardReady = true
        NS.ApplyTrackingAll()   -- the raid is formed: tracking on for those who have it set
        if mode ~= NS.lastAppliedMode then
            ApplyStrategyForMode(mode, NS.lastAppliedMode)
            NS.lastAppliedMode = mode
        end

        if mode == NS.MODE_FARM then
            -- Free-for-all loot in Farm mode — per explicit user direction
            -- ("когда мы переключаемся в режим фарм, нужно менять режим
            -- распределения добычи на каждый за себя"): each bot grinding
            -- independently should be able to pick up its own kills' loot
            -- without a group/master/round-robin loot roll getting in the
            -- way. Requires group lead (the master is always the one who
            -- forms the roster, so this should always succeed once actually
            -- grouped); silently a no-op otherwise, same as any other
            -- lead-only API call.
            if IsRaidLeader() or IsPartyLeader() then
                SetLootMethod("freeforall")
            end
            if not silent then NS.PrintModeLine("Farm mode, " .. #NS.rosterOrder .. " bot(s).") end
        else
            if not silent then NS.PrintModeLine("Quest mode, " .. #NS.rosterOrder .. " bot(s).") end
        end
        if NS.RefreshPanel then NS.RefreshPanel() end
        if onDone then onDone() end
    end)

    if NS.RefreshPanel then NS.RefreshPanel() end
end

-- ============================================================
-- Main ticker: drives polling interval + per-step delays
-- ============================================================
local reviveElapsed = 0

local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(self, dt)
    -- Solo is one of the addon's 3 states, and the point of it is that
    -- NOTHING runs in the background while it's active (see NS.MODE_SOLO) -
    -- there's nobody to poll, revive-check, train, or advance an unload
    -- chain for until an explicit Summon/Free Roam click (or Save) moves
    -- the mode away from Solo again.
    if NS.EffectiveMode() == NS.MODE_SOLO then return end

    -- Background stats/rpg-status polling no longer lives in this ticker at
    -- all — each tracked bot runs its own independent NS.StartBotPollLoop
    -- cycle (see that function's own doc comment), started once when the bot
    -- is first added to the roster. Per explicit user direction, the only
    -- background whispers left are "stats" (every mode) and "rpg status"
    -- (Farm mode) — equipment/strategy/quests polling (the old
    -- NS.PollBotDetails) was removed earlier; each of those is its own
    -- independent per-bot window that fetches its own data on open.

    -- NS.CheckReviveBots is event-driven now (UNIT_HEALTH, see its own doc
    -- comment above) — this timer only still exists to refresh entry.level/
    -- class from the live group unit. RAID_ROSTER_UPDATE (the classWatcher
    -- event below) only fires on group COMPOSITION changes — a bot leveling
    -- up doesn't touch that, so the panel's level number went stale until
    -- the next actual group change (could be minutes). This closes that gap:
    -- a level-up shows up here within NS.REVIVE_INTERVAL seconds regardless.
    reviveElapsed = reviveElapsed + dt
    if reviveElapsed >= NS.REVIVE_INTERVAL then
        reviveElapsed = 0
        NS.RefreshBotLevelsAndClasses()
    end

    -- The vendor chain (NS.active) is just 3 fire-and-forget whispers on
    -- fixed NS.After(STEP_DELAY) timers now (see StartNextInQueue) — it
    -- never waits on a whisper REPLY at any step, so there's nothing here
    -- that can get stuck on a lost reply the way the old stats-gated chain
    -- could. NS.active just needs a dead-entry guard (the bot could vanish
    -- from NS.bots entirely mid-chain, e.g. its name dropped from the
    -- roster) so the queue doesn't stay blocked forever behind a key that
    -- no longer exists.
    if NS.active and not NS.bots[NS.active] then
        NS.active = nil
        StartNextInQueue()
    end

    -- Give up on a "rpg status go grind" reply that never arrived — this is
    -- the one wait state still driven by a shared per-frame timer rather
    -- than a self-contained NS.After, since entry.awaitingRpgAction is set
    -- synchronously from inside the stats/rpg-status whisper watcher (not
    -- from a staggered PollBots slot), so it has no drift-prone gap between
    -- "scheduled" and "sent" to begin with. Without this, a lost reply would
    -- leave that bot skipped by every future Farm poll forever. Bots mid-
    -- vendor-chain (entry.step ~= "idle") are handled by the stuck-chain
    -- check above instead, not here.
    --
    -- awaitingStats and awaitingRpgStatus do NOT need a loop like this any
    -- more — each now times out itself via its own NS.After, started at the
    -- moment its whisper actually goes out (see PollBots) rather than at
    -- scheduling time; per explicit user direction ("неужели нельзя проще
    -- запустить для каждого бота свой тикер с нужным сдвигом во времени"),
    -- a per-bot self-contained timer can't drift out of sync with itself the
    -- way a shared timer keyed off a different event could.
    for _, entry in pairs(NS.bots) do
        if entry.step == "idle" and entry.awaitingRpgAction then
            entry.rpgStatusTimer = (entry.rpgStatusTimer or 0) + dt
            if entry.rpgStatusTimer >= NS.STATS_TIMEOUT then
                entry.awaitingRpgAction = nil
            end
        end
    end

    -- Finalize "trainer" reply collection on silence (STATS_TIMEOUT, same
    -- window the inventory/quest collectors use) — a bot with nothing left
    -- to learn may reply with nothing at all, so silence itself (not any
    -- specific closing line) is what ends collection here. Unconditional
    -- (no mode check) since TrainBots can now fire in any non-Solo mode,
    -- triggered by targeting an NPC rather than a Study-mode-only ticker.
    for key, entry in pairs(NS.bots) do
        if entry.awaitingTrainer then
            entry.trainerTimer = entry.trainerTimer + dt
            if entry.trainerTimer >= NS.STATS_TIMEOUT then
                entry.awaitingTrainer = false
                NS.FinalizeTrainerResult(key, entry)
            end
        end
    end
end)

-- ============================================================
-- Whisper reply parsing: pull money / bag / XP out of a "stats" reply.
-- Reply is color/link coded, e.g.
--   "2g 34s 56c, |h|cff20ff2012/16|h|cffffffff Bag, 0% (0) Dur, 87/148% XP"
-- Identify by content signature (has both "Bag" and "Dur"), matching CleanBot.
-- ============================================================
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("CHAT_MSG_WHISPER")
watcher:SetScript("OnEvent", function(self, event, msg, sender)
    local key = strlower(sender or "")
    local entry = NS.bots[key]
    if not entry then return end

    -- Trainer reply collection (Study mode): multiple whisper lines — a
    -- "--- Can learn from <Name> ---" header, one "[Skill]cost - learned" /
    -- "- too expensive" line per learnable skill, and a "Total cost: ..."
    -- summary. No fixed line count and no single-message signature to key
    -- off of (unlike "stats"' "Bag"+"Dur" pair), so just collect every line
    -- while awaitingTrainer is set; the finalize ticker below (silence
    -- timeout, same STATS_TIMEOUT pattern the inventory/quest collectors
    -- use) is what ends collection — a bot with nothing to learn may send
    -- no reply at all, and the timeout is what catches that case too.
    if entry.awaitingTrainer then
        entry.trainerTimer = 0
        entry.trainerLines[#entry.trainerLines + 1] = msg
        -- Re-extend the chat-hiding window (see SendBotCommand's own
        -- NS.blockedBotNames doc comment) for every line, not just the
        -- first: SendBotCommand only blocks for STEP_DELAY (2s), but this
        -- collection can keep streaming lines in well past that on its own
        -- STATS_TIMEOUT (5s) silence window — without this, replies arriving
        -- after the 2s mark leaked into the visible chat window (confirmed
        -- by the user in-game).
        NS.blockedBotNames[key] = true
        NS.After(NS.STATS_TIMEOUT, function() NS.blockedBotNames[key] = nil end)
        return
    end

    -- RPG-command replies (Farm mode only — see the RPG poll/dispatch
    -- section below for what sends these). Two shapes:
    --   - Plain "rpg status": a multi-line reply, "Status: <NAME>" first,
    --     then 2-3 detail lines (npcOrGo/lastWanderNpc/lastReachNpcOrGo, etc)
    --     we don't need — only the first "Status:" line matters, so the flag
    --     is cleared as soon as it's seen and the detail lines that follow
    --     just fall through unmatched (no need to collect/count them).
    --   - "rpg status go grind": a single confirmation line, either
    --     "RPG-статус -> GO_GRIND" (success) or a rejection ("no grind
    --     position available" — exact text not yet confirmed in-game, so
    --     success is detected positively via "GO_GRIND" and anything else
    --     counts as "no position available").
    --
    -- No "do quest" here any more (per explicit user direction): mod-
    -- playerbots' do-quest state just grabs the first quest in the bot's log
    -- with usable objective locations, with no idea whether that quest is
    -- something a bot can actually finish unsupervised — underwater/escort/
    -- stealth/pixel-hunt objectives routinely got a bot stuck standing at the
    -- objective forever, with nothing in this addon able to tell "stuck" from
    -- "working on it". Without a curated list of bot-safe quest IDs (which
    -- doesn't exist yet), grinding is the only WANDER_NPC follow-up reliable
    -- enough to run unattended.
    --
    -- No "go camp" either any more (per explicit user direction: the master
    -- has to stay with the roster for revive/summon anyway — see the bag-
    -- full chain's own doc comment — so a bot detouring to its own camp was
    -- pure travel-time overhead with no actual benefit). GO_GRIND is the
    -- only "leave it alone" status now.
    if entry.awaitingRpgStatus then
        local status = msg:match("^Status:%s*(%S+)")
        if status then
            entry.awaitingRpgStatus = false
            -- Advances this bot's own poll cycle (see NS.StartBotPollLoop)
            -- the instant a real reply lands, same as the stats watcher.
            local cb = NS.pollCycleCallbacks[key]
            if cb and cb.onRpgStatus then cb.onRpgStatus() end
            Print(string.format("|cff00ff00[TimingDebug]|r %.1f RECV status=%s <- %s", GetTime(), status, entry.name), "farm")
            -- Per explicit user direction, branch on the exact status:
            --   GO_GRIND      -> already grinding, leave it alone.
            --   WANDER_NPC    -> retry "go grind" right away (it's on its way
            --                    to/at an NPC, not actually exploring for a
            --                    grind spot).
            --   WANDER_RANDOM -> only retry "go grind" if this is the SECOND
            --                    consecutive WANDER_RANDOM poll (give it one
            --                    more tick to keep wandering and discover a
            --                    grind position on its own first).
            --   anything else (TRAVEL_FLIGHT, etc) -> summon it back and
            --                    start it wandering again from scratch.
            if status == "GO_GRIND" then
                -- Found a grind spot and is using it — reset both the streak
                -- counter and the threshold it grows, so the next time this
                -- bot runs dry it starts the backoff fresh at 2 rather than
                -- wherever it left off before finally succeeding.
                entry.wanderRandomStreak = 0
                entry.wanderRandomThreshold = nil
            elseif status == "WANDER_NPC" then
                -- Not actually exploring (on its way to/at an NPC) — doesn't
                -- count toward or break the WANDER_RANDOM streak either way,
                -- same as before.
                entry.awaitingRpgAction = "go grind"
                Print(string.format("|cff00ff00[TimingDebug]|r %.1f SEND go grind -> %s", GetTime(), entry.name), "farm")
                SendBotCommand(entry.name, "rpg status go grind")
            elseif status == "WANDER_RANDOM" then
                -- How many consecutive WANDER_RANDOM polls to let through
                -- before retrying "go grind" — starts at 2 (the original
                -- "give it one more tick" behavior) and grows every time
                -- "go grind" comes back empty (see entry.wanderRandomStreak
                -- below), per explicit user direction ("нужно увеличивать
                -- пропуски статуса wander random с каждым разом когда на go
                -- grind бот отвечает, что нет доступной позиции для
                -- гринда") — a bot that keeps failing to find a grind spot
                -- needs progressively more room to wander and actually
                -- discover one, not the same fixed 2-poll window forever.
                entry.wanderRandomStreak = (entry.wanderRandomStreak or 0) + 1
                local threshold = entry.wanderRandomThreshold or 2
                if entry.wanderRandomStreak >= threshold then
                    entry.wanderRandomStreak = 0
                    entry.awaitingRpgAction = "go grind"
                    Print(string.format("|cff00ff00[TimingDebug]|r %.1f SEND go grind (after %d wander random) -> %s", GetTime(), threshold, entry.name), "farm")
                    SendBotCommand(entry.name, "rpg status go grind")
                end
                -- else: let it wander another tick, no command sent
            else
                Print(string.format("|cff00ff00[TimingDebug]|r %.1f SEND summon + wander random -> %s", GetTime(), entry.name), "farm")
                -- Summon must really land before the bot is sent exploring;
                -- key keeps the 30s poll from stacking a second identical
                -- chain while this one is still retrying. No onFail: if the
                -- bot never arrives, the next rpg-status poll just tries again.
                NS.SendBotChain(entry.name, {
                    NS.SummonStep(entry),
                    { cmd = "rpg status wander random" },
                }, { key = "resummon" })
            end
            return
        end
        -- An indented detail line (npcOrGo/lastWanderNpc/lastReachNpcOrGo)
        -- belonging to the "Status:" reply just seen — not itself a status
        -- line, and NOT the next command's reply either. Swallow it here so
        -- it can't fall through into the awaitingRpgAction branch below
        -- (which would otherwise misread it as that command's own reply).
        -- Re-extend the chat-hiding window for it too, same reasoning as the
        -- trainer collector above — SendBotCommand's own STEP_DELAY window
        -- can close before these trailing detail lines arrive.
        if msg:match("^%s") then
            NS.blockedBotNames[key] = true
            NS.After(NS.STEP_DELAY, function() NS.blockedBotNames[key] = nil end)
            return
        end
    end

    if entry.awaitingRpgAction == "go grind" then
        if msg:match("^%s") then return end
        entry.awaitingRpgAction = nil
        Print(string.format("|cff00ff00[TimingDebug]|r %.1f RECV go grind reply=%q <- %s", GetTime(), msg, entry.name), "farm")
        if not strfind(msg, "GO_GRIND", 1, true) then
            -- No grind position known yet — explore so the bot discovers
            -- one; the next regular rpg status poll picks up from wherever
            -- that leaves it (WANDER_NPC/grind/etc), no special follow-up.
            -- Grows the WANDER_RANDOM backoff threshold (see its own doc
            -- comment above) every time "go grind" comes back empty — per
            -- explicit user direction: a bot that keeps failing needs
            -- progressively longer to wander before the next attempt, not
            -- the same fixed window retried forever.
            entry.wanderRandomThreshold = (entry.wanderRandomThreshold or 2) + 2
            Print(string.format("|cff00ff00[TimingDebug]|r %.1f SEND wander random (next go-grind threshold=%d) -> %s", GetTime(), entry.wanderRandomThreshold, entry.name), "farm")
            SendBotCommand(entry.name, "rpg status wander random")
        end
        return
    end

    -- NOT gated on entry.awaitingStats — the "Bag"+"Dur" signature alone
    -- already uniquely identifies a "stats" reply, and requiring the flag
    -- too meant a reply arriving even slightly after this bot's own
    -- NS.STATS_TIMEOUT self-timeout (PollBots) had already force-cleared
    -- awaitingStats back to false got silently dropped here — not just a
    -- missed tick-indicator update but the bot's bagFree/money/xp data
    -- itself never getting applied that pass (confirmed by the user
    -- in-game: "через раз прокакивает мимо последнего бота в ростере" — the
    -- server's own reply latency under bot-AI load routinely exceeds a flat
    -- 5s timeout, especially for whichever bot's slot lands last). Accept
    -- and apply the data whenever it actually arrives; only clear
    -- awaitingStats as a side effect if it's still set.
    if strfind(msg, "Bag", 1, true) and strfind(msg, "Dur", 1, true) then
        entry.awaitingStats = false
        -- Advances this bot's own poll cycle (see NS.StartBotPollLoop) the
        -- instant a real reply lands, instead of waiting for its retry
        -- timeout to notice. No-op if no cycle is currently waiting on this
        -- bot's stats (e.g. a manual "stats" whisper from the user).
        local cb = NS.pollCycleCallbacks[key]
        if cb and cb.onStats then cb.onStats() end
        -- Tick indicator: darkens on THIS bot's reply arriving — see
        -- NS.ClearTickIndicator's own doc comment for why only a genuine
        -- reply (never a timeout/retry) clears it.
        NS.ClearTickIndicator(key)
        local clean = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|h", ""):gsub("|r", "")

        local bagFree, bagTotal = clean:match("(%d+)/(%d+)%s*Bag")
        if bagFree then
            bagFree  = tonumber(bagFree)
            bagTotal = tonumber(bagTotal)
            entry.bagFree  = bagFree
            entry.bagTotal = bagTotal
        end

        local moneyPart = clean:match("^(.-)%d+/%d+%s*Bag") or ""
        entry.money = {
            gold   = tonumber(moneyPart:match("(%d+)g")) or 0,
            silver = tonumber(moneyPart:match("(%d+)s")) or 0,
            copper = tonumber(moneyPart:match("(%d+)c")) or 0,
        }

        -- "cur/rested% XP" — cur is already the level's XP percent (not a
        -- fraction to divide); rested is the separate rested-XP bonus percent
        -- and isn't used for progress tracking.
        local xpCur, xpRested = clean:match("(%d+)/(%d+)%%%s*XP")
        if xpCur then
            local newXpPercent = tonumber(xpCur)

            -- Hourly XP-gain tracking: reset the baseline whenever the wall-clock
            -- hour changes, so the panel always shows "gained since the top of
            -- THIS hour" (e.g. resets at 14:00, 15:00, ...), not a rolling
            -- 60-minute window. time() is real wall-clock time (unlike GetTime(),
            -- which is seconds-since-client-launch and wouldn't align to the hour).
            NS.TrackHourlyXp(entry, newXpPercent)
        end

        -- entry.step ~= "idle" (queued/vendor) is naturally excluded from
        -- ever reaching here in practice — each bot's own poll cycle (see
        -- NS.StartBotPollLoop) only whispers "stats" while idle in the first
        -- place, and the vendor chain (StartNextInQueue) never sends "stats"
        -- itself any more (per explicit user direction — no re-check step
        -- left).
        if bagFree then
            if entry.unloadBase and bagFree > entry.unloadBase then
                entry.unloadTries, entry.unloadBase = 0, nil   -- space appeared: the unloads work again
            end
            entry.lastStatsFree = bagFree
        end
        if bagFree and bagFree == 0 then
            NS.OnBagsFull(key, entry)
        end
        if NS.RefreshPanel then NS.RefreshPanel() end
    end
end)

-- ============================================================
-- "My inventory is full" is the bot AI's own real-time loot-failure cry —
-- confirmed by the user in-game: a bot yells this the instant it can't pick
-- up a loot item, well before the next periodic "stats" poll would ever
-- catch up. It's also strictly more trustworthy than "stats"'s own bagFree
-- number: the server's bagFree/bagTotal count "occupied slots" per distinct
-- ITEM TYPE, not per actual stack — e.g. 2456 arrows at a 1000-per-stack
-- limit physically fill 3 slots but "stats" reports that as 1 occupied slot,
-- so a bot can be visibly screaming "inventory is full" while the panel
-- still shows 1 free slot (confirmed by the user in-game screenshot: "Lara:
-- My inventory is full" spamming chat while the board read "lara 1/46").
-- Catching this line directly means the unload chain no longer depends on
-- stats's undercount at all for the "bags are actually full" case — it's a
-- correction on top of, not a replacement for, the existing bagFree==0
-- watcher above (which still catches the case where stats happens to get it
-- right).
-- ============================================================
local bagsFullCryWatcher = CreateFrame("Frame")
for _, event in ipairs({ "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER" }) do
    bagsFullCryWatcher:RegisterEvent(event)
end
bagsFullCryWatcher:SetScript("OnEvent", function(self, event, msg, sender)
    if not msg or not strfind(strlower(msg), "inventory is full", 1, true) then return end
    -- sender can arrive as "Name" or "Name-Realm" depending on channel/CRZ.
    local senderName = sender and sender:match("^([^%-]+)") or sender
    local key = strlower(senderName or "")
    local entry = NS.bots[key]
    if not entry then return end

    -- The bot just told us its bags are full RIGHT NOW — trust that over
    -- whatever stale/undercounted bagFree "stats" last reported.
    entry.bagFree = 0
    if NS.RefreshPanel then NS.RefreshPanel() end
    NS.OnBagsFull(key, entry)
end)

-- ============================================================
-- Chat filter: hide AltBot's own bot chatter from the visible chat window,
-- but ONLY for the brief window SendBotCommand keeps a bot's name in
-- NS.blockedBotNames (the round-trip of one automated command) — not
-- permanently. A standing "always hide this bot's chat" filter would also
-- swallow the user's own manual whispers to that same bot, which the user
-- explicitly needs to keep working ("мне нужно помимо аддона давать команды
-- ботам"). Same ChatFrame_AddMessageEventFilter mechanism CleanBot uses
-- (display-only, doesn't touch the RegisterEvent handlers above, which keep
-- parsing every line normally regardless of whether it's shown).
-- ============================================================
-- Now driven by the Settings window's "Chat output" checkboxes (see
-- NS.CHAT_CATEGORIES/NS.ChatShown) instead of the brief per-command
-- NS.blockedBotNames window: a category that's unchecked is hidden for every
-- tracked bot, permanently; checked categories are never touched.

--- Which category an incoming whisper from a tracked bot belongs to.
local lastRpgReplyAt = {}   -- lower(bot name) -> GetTime() of its last "Status:" line

local function classifyIncoming(msg, key)
    if strfind(msg, "Bag", 1, true) and strfind(msg, "Dur", 1, true) then return "stats" end
    -- the replies of a window's fetch that is in flight belong to that window
    if NS.questAwaiting and NS.questAwaiting[key] then return "questlog" end
    if NS.equipAwaiting and NS.equipAwaiting[key] then return "armory" end
    if NS.strategyAwaiting and NS.strategyAwaiting[key] then return "strategies" end
    if strfind(msg, "AI was reset to defaults", 1, true) then return "init" end
    if msg:match("^Strategies:") or msg:match("^Loot strategy:") then return "strategies" end
    local now = GetTime()
    if msg:match("^Status:") then
        lastRpgReplyAt[key] = now
        return "farm"
    end
    if strfind(msg, "GO_GRIND", 1, true) or strfind(msg, "RPG-статус", 1, true) then return "farm" end
    -- The indented detail lines (GrindPos/lastGoGrind/...) of an rpg status reply: only when they
    -- directly follow that bot's "Status:" line; item lines never count.
    if msg:match("^%s") and not strfind(msg, "|Hitem:", 1, true)
        and now - (lastRpgReplyAt[key] or -99) < 3 then
        return "farm"
    end
    if msg:match("^[Ss]elling") or msg:match("^[Ss]old") then return "farm" end
    if strfind(msg, "Я снова жив", 1, true) then return "farm" end
    if msg:match("^Casting ") then return "farm" end   -- the answer to a tracking cast
    -- the "who" reply (the armory header)
    if NS.CleanEscapes(msg):match("%[[MF]%]") and NS.CleanEscapes(msg):match("%(%d+/%d+/%d+%)") then return "armory" end
    -- the "items" listing and every reply that carries an item link
    if strfind(msg, "|Hitem:", 1, true) or strfind(msg, "=== Inventory ===", 1, true)
        or msg:match("^%-%-%- .+ %-%-%-$") then
        return "inventory"
    end
    return "reply"
end

-- The armory's per-slot equipment queries (EQUIP_SLOT_KEYWORD, defined much
-- further down) - plain whispers of just the slot name.
local EQUIP_QUERY_WORDS = {
    ["head"] = true, ["neck"] = true, ["shoulder"] = true, ["shirt"] = true, ["chest"] = true,
    ["waist"] = true, ["legs"] = true, ["feet"] = true, ["wrist"] = true, ["hands"] = true,
    ["finger 1"] = true, ["finger 2"] = true, ["trinket 1"] = true, ["trinket 2"] = true,
    ["back"] = true, ["main hand"] = true, ["off hand"] = true, ["ranged"] = true, ["tabard"] = true,
}

--- Which category a whisper this addon (or the user) sent to a bot belongs to.
local function classifyOutgoing(msg)
    if EQUIP_QUERY_WORDS[msg] or msg == "who" then return "armory" end
    if msg == "stats" then return "stats" end
    if msg == "reset botAI" then return "init" end
    if msg:match("^nc%s") or msg:match("^co%s") or msg:match("^ll%s") then return "strategies" end
    if strfind(msg, "^rpg status") or msg == "summon" or msg == "s *" or msg == "s vendor"
        or strfind(msg, "^cast Find ") then
        return "farm"
    end
    if msg == "items" or msg:match("^s%s") or msg:match("^t%s") or msg:match("^e%s")
        or msg:match("^guild bank%s") or msg:match("^destroy%s") then
        return "inventory"
    end
    if msg == "quests all" or msg:match("^drop%s") then return "questlog" end
    if msg == "spells" or msg:match("^cast%s") then return "spellbook" end
    return "cmd"
end
NS.ClassifyOutgoing = classifyOutgoing

--- The chat category of a chain's command: its own area, "init" for anything unclassified.
NS.ChainCategory = function(cmd)
    local c = type(cmd) == "table" and cmd[1] or cmd
    local cat = classifyOutgoing(tostring(c or ""))
    if cat == "cmd" or cat == "reply" then return "init" end
    return cat
end

--- Whether `key` (lowercase name) is a tracked bot. Also true for a name in
--- the SAVED roster text while NS.bots isn't built yet — right after login a
--- bot can still answer a command sent before the reload/disconnect, and that
--- reply arrives before BuildRosterFromNames has run (it waits for the group
--- roster), which is how an "rpg status" reply slipped into chat.
local rosterSetText, rosterSet = nil, {}
local function IsTrackedBotName(key)
    if NS.bots[key] then return true end
    local text = AltBot_SavedVars and AltBot_SavedVars.rosterText
    if not text or text == "" then return false end
    if rosterSetText ~= text then
        rosterSetText, rosterSet = text, {}
        for _, n in ipairs(ParseRosterText(text).botNames or {}) do rosterSet[strlower(n)] = true end
    end
    return rosterSet[key] == true
end

--- Incoming whispers FROM a tracked bot (stats/reset/summon/etc replies).
local function filterIncomingWhisper(_, _, msg, sender)
    local key = strlower(sender or "")
    if not msg or not IsTrackedBotName(key) then return false end
    -- the spellbook's "spells" reply (many plain lines): its category while it is being collected
    if GetTime() < (NS.spellHideUntil[key] or 0) then return not NS.ChatShown("spellbook") end
    local category = classifyIncoming(msg, key)
    -- an unclassified reply that comes right after a command the addon sent is part of the addon's
    -- traffic: "init". (A reply to the user's own manual command stays visible.)
    if category == "reply" and GetTime() - (NS.addonWhisperLast[key] or -99) < 3 then category = "init" end
    return not NS.ChatShown(category)
end

--- Outgoing whispers TO a tracked bot (the commands this addon sends). For
--- CHAT_MSG_WHISPER_INFORM the "sender" slot (4th arg after self/event/msg)
--- actually holds the RECIPIENT — standard WoW *_INFORM semantics, matching
--- how CleanBot's own filter reads this same event.
local function filterOutgoingWhisper(_, _, msg, recipient)
    local key = strlower(recipient or "")
    if not msg or not IsTrackedBotName(key) then return false end
    local category = classifyOutgoing(msg)
    -- a command the ADDON whispered that fits no area (follow, stay, co ... reaction...): "init"
    if category == "cmd" and GetTime() - (NS.addonWhisperAt[key .. "|" .. msg] or -99) < 3 then category = "init" end
    return not NS.ChatShown(category)
end

-- The client's own strings for group changes and the loot method, turned into patterns; a line that
-- matches is the consequence of what the addon did when the name in it is a tracked bot (or there is none).
NS.GROUP_LINE_CONSTANTS = { "ERR_RAID_MEMBER_ADDED_S", "ERR_RAID_MEMBER_REMOVED_S", "ERR_JOINED_GROUP_S",
    "ERR_LEFT_GROUP_S", "ERR_LEFT_GROUP_YOU", "ERR_RAID_YOU_JOINED", "ERR_RAID_YOU_LEFT", "ERR_GROUP_DISBANDED",
    "ERR_RAID_CONVERTED", "ERR_SET_LOOT_FREEFORALL", "ERR_SET_LOOT_ROUNDROBIN", "ERR_SET_LOOT_MASTER",
    "ERR_SET_LOOT_GROUP", "ERR_SET_LOOT_NBG" }
NS.groupLinePatterns = nil
NS.IsAddonGroupLine = function(msg)
    if not NS.groupLinePatterns then
        NS.groupLinePatterns = {}
        for _, constName in ipairs(NS.GROUP_LINE_CONSTANTS) do
            local fmt = _G[constName]
            if type(fmt) == "string" then
                local pat = fmt:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"):gsub("%%%%s", "(.+)")
                NS.groupLinePatterns[#NS.groupLinePatterns + 1] = "^" .. pat .. "$"
            end
        end
    end
    local plain = NS.CleanEscapes(msg)
    for _, pat in ipairs(NS.groupLinePatterns) do
        local first, _, who = plain:find(pat)
        if first then
            -- a line without a name (you left, loot method...) or with a tracked bot's / the master's name
            return who == nil or IsTrackedBotName(strlower(who)) or who == UnitName("player")
        end
    end
    return false
end

-- System lines from ".playerbots bot add/remove/list" — the per-name result
-- lines ("<cmd>: <Name> - <result>") and the "Bot roster:" list dump.
local BOT_CMD_RESULT_WORDS = {
    "player already logged in",
    "player is offline",
    "not your bot",
    " - ok",
    "logged in",
}
local function filterSystemLine(_, _, msg)
    if not msg then return false end
    -- AFK on/off notices (the anti-AFK keypress toggles them over and over):
    -- always hidden, no checkbox, per explicit user direction.
    if msg:match("^Вы отошли от компьютера") or msg:match("^Вы вернулись%.")
        or msg:match("^You are now AFK") or msg:match("^You are no longer AFK") then
        return true
    end
    -- Server broadcast nagging to join the Global channel (colour codes may
    -- precede the text, so match anywhere): also always hidden.
    if strfind(msg, "присоединиться к глобальному чату", 1, true) then return true end
    -- "chat items": the client's own "Вы предложили <Бот> обмен." line that
    -- opening a trade with a tracked bot (bags window Trade) prints.
    local tradedWith = msg:match("^Вы предложили (%S+) обмен")
    if tradedWith and IsTrackedBotName(strlower(tradedWith)) and not NS.ChatShown("inventory") then
        return true
    end
    -- what the addon's own actions cause: bots joining/leaving the group, the loot method change
    if not NS.ChatShown("init") and NS.IsAddonGroupLine(msg) then return true end
    if NS.ChatShown("init") then return false end   -- bot add/remove results: "init"
    local lower = strlower(msg)
    if lower:find("[Bb]ot roster", 1) then return true end
    if msg:match("^%a+:%s+%S+%s+%-%s+") then
        for _, word in ipairs(BOT_CMD_RESULT_WORDS) do
            if lower:find(word, 1, true) then return true end
        end
    end
    return false
end

-- Re-enabled (they were off while Trade/Sell whisper traffic was being
-- diagnosed — "разблокируй временно чат"). With the category checkboxes in
-- place they only ever hide what the user unchecked (stats / rpg status by
-- default); everything else stays visible.
-- What the bots SAY/YELL/EMOTE or put into party/raid chat (the "Привет!" after a summon...) and the
-- echo of the commands the addon itself sends to the group ("summon" to the raid...): hidden unless
-- "chat init" (bots' chatter) or the command's own category is on. The user's own typing stays.
local function filterGroupChat(_, event, msg, sender)
    if not msg or not sender then return false end
    local name = sender:match("^([^%-]+)") or sender
    if IsTrackedBotName(strlower(name)) then return not NS.ChatShown("init") end
    if name == UnitName("player") and GetTime() - (NS.groupSent[msg] or -99) < 3 then
        return not NS.ChatShown(NS.ChainCategory(msg))
    end
    return false
end
for _, ev in ipairs({ "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
                      "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING", "CHAT_MSG_EMOTE" }) do
    ChatFrame_AddMessageEventFilter(ev, filterGroupChat)
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER",        filterIncomingWhisper)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", filterOutgoingWhisper)
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM",         filterSystemLine)

-- ============================================================
-- Level/class tracking: UnitLevel/UnitClass only work while the bot is a
-- unit we can query (grouped). Farm mode groups its roster and stays
-- grouped; this just keeps the panel's class/level fresh whenever a tracked
-- bot happens to be grouped (Farm mode, or Quest mode's incidental party).
-- ============================================================

--- Re-reads level/class for every tracked bot currently reachable as a
--- group unit. Shared by classWatcher's RAID_ROSTER_UPDATE handler (group
--- COMPOSITION changes — join/leave/convert) and the main ticker's
--- REVIVE_INTERVAL sweep (catches level-ups, which don't fire
--- RAID_ROSTER_UPDATE at all — see the ticker call site).
NS.RefreshBotLevelsAndClasses = function()
    NS.SyncWildBots()
    ForEachGroupMember(function(unit, name)
        if not name then return end
        local entry = NS.bots[strlower(name)]
        if not entry then return end
        local _, class = UnitClass(unit)
        entry.class = class or entry.class
        entry.level = UnitLevel(unit) or entry.level
    end)
    if NS.RefreshPanel then NS.RefreshPanel() end
    -- Also catch up any open armory windows' unit token/model — display-only
    -- (re-resolves f.unit and repaints from cache), no NotifyInspect fired
    -- here.
    if NS.RepaintOpenDetailFrame then
        NS.RepaintOpenDetailFrame()
    end
end

--- Hourly XP-gain bookkeeping shared by bots and the master: a new baseline at the top
--- of every wall-clock hour; a level-up (the % drops) banks the part earned up to it.
--- Persisted in AltBot_SavedVars.xpHour (per name) so it survives /reload, per explicit
--- user direction ("+%xp должен переживать релоад").
NS.TrackHourlyXp = function(e, pct)
    local key = e.name and strlower(e.name)
    local saved
    if key and AltBot_SavedVars then
        AltBot_SavedVars.xpHour = AltBot_SavedVars.xpHour or {}
        saved = AltBot_SavedVars.xpHour
        if not e.xpHourLoaded and saved[key] then
            local r = saved[key]
            e.xpHourStamp, e.xpHourBase, e.xpHourCarry, e.xpPercent = r[1], r[2], r[3], r[4]
        end
        e.xpHourLoaded = true
    end
    local hourStamp = math.floor(time() / 3600)
    if e.xpHourStamp ~= hourStamp then
        e.xpHourStamp = hourStamp
        e.xpHourBase = pct
        e.xpHourCarry = 0
    elseif e.xpPercent and pct < e.xpPercent then
        e.xpHourCarry = (e.xpHourCarry or 0) + (100 - (e.xpHourBase or 0))
        e.xpHourBase = 0
    end
    e.xpPercent = pct
    if saved then saved[key] = { e.xpHourStamp, e.xpHourBase, e.xpHourCarry, pct } end
end

--- The board's per-bot numbers persist (AltBot_SavedVars.botStats[key]) so a column shows its
--- last known values right after login/reload instead of "?" (per explicit user direction); the
--- next "stats" reply refreshes them. Wild-class bots are never saved.
NS.PersistBotStats = function(entry)
    if entry.wild or not AltBot_SavedVars or not entry.name then return end
    AltBot_SavedVars.botStats = AltBot_SavedVars.botStats or {}
    local key = strlower(entry.name)
    local rec = AltBot_SavedVars.botStats[key]
    if not rec then
        rec = {}
        AltBot_SavedVars.botStats[key] = rec
    end
    rec.class, rec.level, rec.bagFree, rec.bagTotal = entry.class, entry.level, entry.bagFree, entry.bagTotal
    local m = entry.money
    if m then
        rec.gold, rec.silver, rec.copper = m.gold, m.silver, m.copper
    end
end

--- Fills a just-created tracked entry from the saved record (and from the saved hourly-XP state,
--- brought up to date: a record of an earlier hour starts a fresh baseline at the saved %).
NS.RestoreBotStats = function(entry)
    local key = strlower(entry.name)
    local rec = AltBot_SavedVars and AltBot_SavedVars.botStats and AltBot_SavedVars.botStats[key]
    if rec then
        entry.class, entry.level, entry.bagFree, entry.bagTotal = rec.class, rec.level, rec.bagFree, rec.bagTotal
        if rec.gold then entry.money = { gold = rec.gold, silver = rec.silver or 0, copper = rec.copper or 0 } end
    end
    local hour = AltBot_SavedVars and AltBot_SavedVars.xpHour and AltBot_SavedVars.xpHour[key]
    if hour and hour[4] then
        entry.xpPercent = hour[4]
        local stamp = math.floor(time() / 3600)
        if hour[1] == stamp then
            entry.xpHourStamp, entry.xpHourBase, entry.xpHourCarry = hour[1], hour[2], hour[3]
        else
            entry.xpHourStamp, entry.xpHourBase, entry.xpHourCarry = stamp, hour[4], 0
        end
        entry.xpHourLoaded = true
    end
end

local classWatcher = CreateFrame("Frame")
classWatcher:RegisterEvent("RAID_ROSTER_UPDATE")
classWatcher:SetScript("OnEvent", NS.RefreshBotLevelsAndClasses)

-- ============================================================
-- Panel UI: one column per tracked FARMING bot (the trainer is tracked
-- in-memory but intentionally not shown — nothing about it changes). Hourly
-- XP% gain on top, then a class icon row, then the name (class-colored),
-- then 4 data rows: bags / money / xp% / level. Draggable, position
-- remembered via AltBot_SavedVars.
-- ============================================================
local COL_WIDTH  = 36   -- 20px narrower, per explicit user direction ("табло плотнее")
local COL_MARGIN = 4
local ROW_HEIGHT = 14
local MAX_COLS   = 8
local ICON_SIZE  = 18
local TOP_PAD    = 5   -- gap above the XP-gain row so the 3px top border (holdBorder) doesn't cover it

-- Class-icon atlas UV coords, same "Interface\WorldStateFrame\Icons-Classes"
-- sheet CleanBot uses (NS.CLASS_ICON_COORDS in its ClassData.lua).
local CLASS_ICON_COORDS = {
    WARRIOR     = {0,    0.25,  0,    0.25},
    MAGE        = {0.25, 0.5,   0,    0.25},
    ROGUE       = {0.5,  0.75,  0,    0.25},
    DRUID       = {0.75, 1.0,   0,    0.25},
    HUNTER      = {0,    0.25,  0.25, 0.5},
    SHAMAN      = {0.25, 0.5,   0.25, 0.5},
    PRIEST      = {0.5,  0.75,  0.25, 0.5},
    WARLOCK     = {0.75, 1.0,   0.25, 0.5},
    PALADIN     = {0,    0.25,  0.5,  0.75},
    DEATHKNIGHT = {0.25, 0.5,   0.5,  0.75},
}

-- ============================================================
-- The board ("табло"): several INDEPENDENT frames - one per raid group that has a
-- tracked bot in it (a single frame when not in a raid) - each draggable on its
-- own, each remembering its own position. The master is the first column of the
-- first frame, with the same stats as a bot (hourly XP gain, class icon, name,
-- bags, money, XP%, level) but his clicks open the standard game windows.
-- Per bot: hourly XP% gain on top, a class icon, the name (class-colored), then
-- bags / money / xp% / level.
-- ============================================================
NS.boardFrames = {}    -- frame index (raid subgroup 1..8) -> frame
NS.boardColumns = {}   -- every column of every frame (the tick indicators look bots up here)

--- True while at least one board frame is on screen.
NS.BoardAnyShown = function()
    for _, f in pairs(NS.boardFrames) do
        if f:IsShown() then return true end
    end
    return false
end

--- Shows/hides the whole board and persists the choice (account-wide, like the
--- positions). Toggled by the minimap icon's right-click. Shown by default (nil
--- reads as shown).
NS.SetPanelShown = function(shown)
    AltBot_SavedVars.panelShown = shown and true or false
    NS.RefreshPanel()
end
NS.TogglePanel = function()
    NS.SetPanelShown(AltBot_SavedVars.panelShown == false)
end

--- Farm mode only: first click summons this one bot to the master, sells its
--- bags (NS.SellCommand) and resets its botAI so it stops grinding/wandering
--- and stays put (entry.farmHeld, shown as the column's top border); second
--- click puts it back on the farming strategy and sends it exploring again.
--- Affects only this bot - everyone else keeps farming. Commands go out
--- back-to-back with no NS.STEP_DELAY gaps, per explicit user direction
--- ("выдав ему в чат summon, можно сразу же выдавать s").
NS.ToggleFarmHold = function(key)
    local entry = NS.bots[key]
    if not entry or NS.EffectiveMode() ~= NS.MODE_FARM then return end

    if not entry.farmHeld then
        NS.SetFarmHeld(entry, true)
        entry.awaitingRpgStatus = false
        entry.awaitingRpgAction = nil
        NS.CancelBotChains(entry.name)
        -- Summon must really land (tradeable bot) and reset botAI must be
        -- confirmed by the bot's reply - both critical, retried (see
        -- NS.SummonStep/NS.ResetStep); only then sell (per explicit user
        -- direction: reset first, with waiting for its reply, then s).
        local sellSteps = NS.SellAndRecheckSteps(NS.STEP_DELAY)
        NS.SendBotChain(entry.name, {
            NS.SummonStep(entry),
            NS.ResetStep(),
            sellSteps[1],   -- sell, then "stats" only if something was sold
            sellSteps[2],
        }, {
            onFail = function(failedCmd)
                -- Never got the bot parked cleanly: don't leave it marked as
                -- parked - release it back to normal polling.
                Print(entry.name .. ": '" .. tostring(failedCmd) .. "' not confirmed, not parking", "farm")
                NS.SetFarmHeld(entry, false)
                if NS.RefreshPanel then NS.RefreshPanel() end
            end,
        })
    else
        NS.SetFarmHeld(entry, false)
        entry.wanderRandomStreak = 0
        entry.wanderRandomThreshold = nil
        NS.CancelBotChains(entry.name)
        -- Back to Farm must be verified (strategy confirmed via "nc ?").
        NS.SendBotChain(entry.name, {
            NS.FarmStrategyStep(),
            { cmd = "rpg status wander random" },
        }, {
            onFail = function(failedCmd)
                Print(entry.name .. ": '" .. tostring(failedCmd) .. "' not confirmed, farm strategy not set", "farm")
            end,
        })
    end
    if NS.RefreshPanel then NS.RefreshPanel() end
end

-- Which rows of a board column are shown, per explicit user direction: the settings window has a "hide ..." checkbox
-- per row (account-wide AltBot_SavedVars.hide[key]); the visible rows are stacked without gaps, and even with every
-- row hidden the column stays as a small block that can still be right-clicked (the menu, see NS.ShowBoardMenu).
NS.HIDE_ROWS = { { key = "gain", label = "hide gains" }, { key = "icon", label = "hide icons" },
    { key = "name", label = "hide names" }, { key = "bags", label = "hide bags" },
    { key = "gold", label = "hide gold" }, { key = "xp", label = "hide xp" }, { key = "level", label = "hide levels" } }
NS.ROW_HEIGHTS = { gain = 12, icon = 20, name = 14, bags = 12, gold = 12, xp = 12, level = 12 }   -- tight rows, per explicit user direction
NS.RowHidden = function(key)
    local hide = AltBot_SavedVars and AltBot_SavedVars.hide
    return (hide and hide[key]) and true or false
end
--- The height of a column with the currently visible rows (never less than a clickable block).
NS.ColumnHeight = function()
    local h = TOP_PAD
    for _, row in ipairs(NS.HIDE_ROWS) do
        if not NS.RowHidden(row.key) then h = h + NS.ROW_HEIGHTS[row.key] end
    end
    return math.max(h, 24)
end
--- Stacks the visible rows of column `f` from the top and hides the others.
NS.ApplyColumnLayout = function(f)
    local elements = { gain = f.xpGain, icon = f.classIconBtn, name = f.name, bags = f.bags, gold = f.money,
        xp = f.xp, level = f.lvl }
    local buttons = { gain = f.xpGainBtn, name = f.nameBtn, bags = f.bagsBtn, xp = f.xpBtn, level = f.lvlBtn }
    local y = TOP_PAD
    for _, row in ipairs(NS.HIDE_ROWS) do
        local key = row.key
        local element, button = elements[key], buttons[key]
        if NS.RowHidden(key) then
            element:Hide()
            if button then button:Hide() end
        else
            element:ClearAllPoints()
            element:SetPoint("TOP", f, "TOP", 0, -y)
            if key ~= "icon" then element:Show() end   -- the icon button is shown/hidden by the class being known
            if button then button:Show() end
            y = y + NS.ROW_HEIGHTS[key]
        end
    end
    f:SetHeight(NS.ColumnHeight())
end

local function CreateColumn(parent)
    NS.boardColumnSerial = (NS.boardColumnSerial or 0) + 1
    local f = CreateFrame("Frame", "AltBotCol" .. NS.boardColumnSerial, parent)
    f:SetSize(COL_WIDTH, NS.ColumnHeight())

    -- A faint block behind the column: with every row hidden this is what is left to click on.
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(f)
    f.bg:SetTexture(1, 1, 1, 0.06)

    -- Row 0 (top): hourly XP% gain.
    f.xpGain = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.xpGain:SetPoint("TOP", f, "TOP", 0, -TOP_PAD)
    f.xpGain:SetTextColor(0.4, 0.8, 1.0)

    -- Row 1: class icon - a clickable button (not a bare texture) so it can
    -- open the bot's armory window on click.
    f.classIconBtn = CreateFrame("Button", nil, f)
    f.classIconBtn:SetSize(ICON_SIZE, ICON_SIZE)
    f.classIconBtn:SetPoint("TOP", f.xpGain, "BOTTOM", 0, -2)

    f.classIcon = f.classIconBtn:CreateTexture(nil, "ARTWORK")
    f.classIcon:SetAllPoints(f.classIconBtn)
    f.classIcon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")

    -- Row 2: name, colored by class.
    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.name:SetPoint("TOP", f.classIconBtn, "BOTTOM", 0, -2)

    -- Row 3-6: bags / money / xp% / level.
    f.bags  = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.money = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.xp    = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.lvl   = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    f.bags:SetPoint("TOP", f.name, "BOTTOM", 0, -3)
    f.money:SetPoint("TOP", f.bags, "BOTTOM", 0, -2)
    f.xp:SetPoint("TOP", f.money, "BOTTOM", 0, -2)
    f.lvl:SetPoint("TOP", f.xp, "BOTTOM", 0, -2)

    -- Tick indicator: lights up on THIS bot when its own slot opens, goes dark
    -- when its reply is in or the slot is over (see NS.SetTickIndicator /
    -- NS.ClearTickIndicator). A plain solid-color strip along the column's bottom
    -- edge (no font/art-file dependency to go missing), grey.
    f.tickDot = f:CreateTexture(nil, "OVERLAY")
    f.tickDot:SetHeight(3)
    f.tickDot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    f.tickDot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f.tickDot:SetTexture(0.6, 0.6, 0.6, 1)
    f.tickDot:Hide()

    -- Top-edge twin of tickDot: lit while this bot is parked at the master
    -- (entry.farmHeld, see NS.ToggleFarmHold) - the same 3px strip, white.
    f.holdBorder = f:CreateTexture(nil, "OVERLAY")
    f.holdBorder:SetHeight(3)
    f.holdBorder:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.holdBorder:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    f.holdBorder:SetTexture(1, 1, 1, 1)
    f.holdBorder:Hide()

    -- Transparent click targets, fixed size and a single CENTER anchor on the row
    -- (anchoring to a FontString's own corners froze them at its empty initial
    -- size, confirmed in-game): the top row (park/release in Farm), the bags row,
    -- the name row and the xp row.
    f.xpGainBtn = CreateFrame("Button", nil, f)
    f.xpGainBtn:SetSize(COL_WIDTH, 12)
    f.xpGainBtn:SetPoint("CENTER", f.xpGain, "CENTER", 0, 0)

    f.bagsBtn = CreateFrame("Button", nil, f)
    f.bagsBtn:SetSize(COL_WIDTH, 12)
    f.bagsBtn:SetPoint("CENTER", f.bags, "CENTER", 0, 0)

    f.nameBtn = CreateFrame("Button", nil, f)
    f.nameBtn:SetSize(COL_WIDTH, 12)
    f.nameBtn:SetPoint("CENTER", f.name, "CENTER", 0, 0)

    f.xpBtn = CreateFrame("Button", nil, f)
    f.xpBtn:SetSize(COL_WIDTH, 12)
    f.xpBtn:SetPoint("CENTER", f.xp, "CENTER", 0, 0)

    -- Level row: the bot's spellbook window (until talents get this row).
    f.lvlBtn = CreateFrame("Button", nil, f)
    f.lvlBtn:SetSize(COL_WIDTH, 12)
    f.lvlBtn:SetPoint("CENTER", f.lvl, "CENTER", 0, 0)

    -- Status highlight strip behind the whole column, shown while the chain
    -- is actively working this bot (reset/summon/vendor/restore).
    f.activeGlow = f:CreateTexture(nil, "BACKGROUND")
    f.activeGlow:SetPoint("TOPLEFT", f, "TOPLEFT", -4, 4)
    f.activeGlow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -4)
    f.activeGlow:SetTexture(1.0, 0.85, 0.2, 0.25)
    f.activeGlow:Hide()

    -- Drag & drop of a member between raid groups (see NS.BoardDragStart/Stop): any of the
    -- column's clickable parts can be dragged; a plain click still works as before.
    -- Only the class icon is the handle (per explicit user direction): the rest of the board
    -- frame still drags the frame itself.
    f.classIconBtn:RegisterForDrag("LeftButton")
    f.classIconBtn:SetScript("OnDragStart", function() NS.BoardDragStart(f) end)
    f.classIconBtn:SetScript("OnDragStop", function() NS.BoardDragStop() end)

    -- The column itself takes the mouse (so even an empty column can be right-clicked); dragging it with
    -- the left button moves the whole board frame it sits in.
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        local board = f:GetParent()
        if board and board.StartMoving then board:StartMoving() end
    end)
    f:SetScript("OnDragStop", function()
        local board = f:GetParent()
        local stop = board and board:GetScript("OnDragStop")
        if stop then stop(board) end
    end)
    -- Right click anywhere on the column (its rows included): the menu.
    for _, part in ipairs({ f, f.classIconBtn, f.xpGainBtn, f.bagsBtn, f.nameBtn, f.xpBtn, f.lvlBtn }) do
        part:SetScript("OnMouseUp", function(_, button)
            if button == "RightButton" then NS.ShowBoardMenu(f) end
        end)
    end

    NS.ApplyColumnLayout(f)
    f:Hide()
    NS.boardColumns[#NS.boardColumns + 1] = f
    return f
end

--- Builds (once) and returns board frame `idx`: its own movable frame with its own
--- remembered position (AltBot_SavedVars.boardPoints[idx], account-wide).
NS.GetBoardFrame = function(idx)
    local f = NS.boardFrames[idx]
    if f then return f end

    f = CreateFrame("Frame", "AltBotBoard" .. idx, UIParent)
    f.idx = idx
    f:SetScale(((AltBot_SavedVars and AltBot_SavedVars.boardScale) or 100) / 100)
    f.columns = {}
    f:SetSize(COL_WIDTH + COL_MARGIN * 2, ROW_HEIGHT * 6 + ICON_SIZE + TOP_PAD + COL_MARGIN * 2)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        AltBot_SavedVars.boardPoints = AltBot_SavedVars.boardPoints or {}
        AltBot_SavedVars.boardPoints[idx] = { point, relPoint, x, y }
    end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.35)

    -- Saved position (the old single-board position seeds frame 1), else a default
    -- that keeps the frames apart: stacked downward from the old board's spot.
    local saved = AltBot_SavedVars.boardPoints and AltBot_SavedVars.boardPoints[idx]
        or (idx == 1 and AltBot_SavedVars.panelPoint) or nil
    f:ClearAllPoints()
    if saved then
        f:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", math.floor((idx - 1) / 5) * 180, 200 - ((idx - 1) % 5) * 128)
    end
    f:Hide()
    NS.boardFrames[idx] = f
    return f
end

--- Lays out `count` columns of board frame `f` in a single centered row and
--- resizes the frame to fit (creating columns on demand).
NS.LayoutBoardFrame = function(f, count)
    -- A frame always has room for 5 members (a raid group); free places stay empty, per
    -- explicit user direction ("если фрейм табло не полный, то показывать пустое место").
    local places = math.max(count, 5)
    -- no gap between the columns (per explicit user direction): they touch, the frame keeps a margin around them
    local width = places * COL_WIDTH + COL_MARGIN * 2
    f:SetWidth(width)
    f:SetHeight(NS.ColumnHeight() + COL_MARGIN * 2)
    for i = 1, count do
        local col = f.columns[i]
        if not col then
            col = CreateColumn(f)
            f.columns[i] = col
        end
        col:ClearAllPoints()
        col:SetPoint("CENTER", f, "CENTER",
            -width / 2 + COL_MARGIN + COL_WIDTH / 2 + (i - 1) * COL_WIDTH, 0)
        col:Show()
    end
    for i = count + 1, #f.columns do
        f.columns[i]:Hide()
    end
end

-- ------------------------------------------------------------------
-- The master as a column: a pseudo-entry kept like a bot's (level, bags, money,
-- xp% and the hourly XP baseline), refreshed from the game itself.
-- ------------------------------------------------------------------
NS.masterEntry = { step = "idle" }

NS.UpdateMasterEntry = function()
    local e = NS.masterEntry
    e.name = UnitName("player")
    local _, class = UnitClass("player")
    e.class = class
    e.level = UnitLevel("player")

    local free, total = 0, 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            total = total + slots
            free = free + (GetContainerNumFreeSlots(bag) or 0)
        end
    end
    e.bagFree, e.bagTotal = free, total

    local copper = GetMoney() or 0
    e.money = { gold = math.floor(copper / 10000), silver = math.floor((copper % 10000) / 100), copper = copper % 100 }

    local cur, max = UnitXP("player"), UnitXPMax("player")
    if max and max > 0 then
        local pct = math.floor(cur * 100 / max)
        -- Same hourly bookkeeping as for a bot (see the stats parser): a new baseline
        -- at the top of every wall-clock hour; a level-up (the % drops) banks the part
        -- earned up to it.
        NS.TrackHourlyXp(e, pct)
    end
end

-- Keeps the master's column current: game events mark the board dirty, and a light
-- ticker redraws it at most twice a second (BAG_UPDATE alone can fire in bursts).
NS.boardDirty = false
NS.boardEventFrame = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_MONEY", "BAG_UPDATE",
                      "PLAYER_ENTERING_WORLD", "PARTY_MEMBERS_CHANGED", "RAID_ROSTER_UPDATE" }) do
    NS.boardEventFrame:RegisterEvent(ev)
end
NS.boardEventFrame:SetScript("OnEvent", function() NS.boardDirty = true end)
NS.boardEventFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = (self.elapsed or 0) + dt
    if self.elapsed < 0.5 then return end
    self.elapsed = 0
    if NS.boardDirty then
        NS.boardDirty = false
        if NS.RefreshPanel then NS.RefreshPanel() end
    end
end)

local STEP_LABEL = {
    idle   = nil,
    queued = "queued",
    vendor = "selling...",
}


-- Board shows gold only - per explicit user direction ("только голду без серебра и
-- меди"); full g/s/c is shown only in the per-bot bags window (FormatMoneyFull below).
local function FormatMoney(money)
    if not money then return "?" end
    return money.gold .. "g"
end

local function FormatMoneyFull(money)
    if not money then return "?" end
    return money.gold .. "g " .. money.silver .. "s " .. money.copper .. "c"
end

-- Tracks which bots currently have their OWN tick-indicator lit - a set, since
-- every bot's indicator is fully independent of every other bot's.
-- RefreshPanel's own column rebuild reads this to restore the right dots after a
-- re-layout, instead of losing them until the next send/reply.
local activeTickKeys = {}   -- lower(name) -> true while that bot's own indicator is lit

--- Lights up `key`'s own tick-indicator when its poll slot opens. Never touches any
--- other bot's indicator. Safe to call with a key that has no column right now.
NS.SetTickIndicator = function(key)
    activeTickKeys[key] = true
    for _, f in ipairs(NS.boardColumns) do
        if f.botKey == key then f.tickDot:Show() end
    end
end

--- Darkens `key`'s own tick-indicator (reply in, or its slot is over). Never
--- touches any other bot's indicator.
NS.ClearTickIndicator = function(key)
    activeTickKeys[key] = nil
    for _, f in ipairs(NS.boardColumns) do
        if f.botKey == key then f.tickDot:Hide() end
    end
end

--- Which tracked bots sit in which board frame (raid subgroup, or frame 1 for a
--- party) and in what order; the master goes first in frame 1.
NS.ComputeBoardGroups = function()
    local groups = {}
    local function add(idx, member)
        groups[idx] = groups[idx] or {}
        groups[idx][#groups[idx] + 1] = member
    end
    local masterPlaced = false
    local nRaid = GetNumRaidMembers()
    if nRaid > 0 then
        for i = 1, nRaid do
            local name, _, subgroup = GetRaidRosterInfo(i)
            local key = name and strlower(name)
            if key and NS.bots[key] then
                add(subgroup or 1, { key = key })
            elseif name and UnitIsUnit("raid" .. i, "player") then
                -- The master sits exactly where the raid roster puts him (per explicit
                -- user direction), not forced first in frame 1.
                add(subgroup or 1, { master = true })
                masterPlaced = true
            end
        end
    else
        for i = 1, GetNumPartyMembers() do
            local name = UnitName("party" .. i)
            local key = name and strlower(name)
            if key and NS.bots[key] then
                add(1, { key = key })
            end
        end
    end
    -- The board is just an extra raid frame: only bots actually in the group are shown.
    if not masterPlaced then
        -- party (no raid): the player is first in the party list
        groups[1] = groups[1] or {}
        table.insert(groups[1], 1, { master = true })
    end
    return groups
end

--- Sets a column's name, cutting trailing characters until it fits the column width
--- (per explicit user direction: "имена в таком случае сокращать"). Cuts on UTF-8
--- character boundaries so Cyrillic names stay valid.
NS.SetFittedName = function(fs, name)
    fs:SetText(name)
    local maxWidth = COL_WIDTH
    local text = name
    while fs:GetStringWidth() > maxWidth and #text > 1 do
        local cut = #text
        while cut > 1 and text:byte(cut) >= 128 and text:byte(cut) < 192 do cut = cut - 1 end
        text = text:sub(1, cut - 1)
        fs:SetText(text)
    end
end

--- Draws one bot's data into board column `f` (and wires its clicks).
local function FillBotColumn(f, key, entry)
    f.botKey = key   -- lets NS.SetTickIndicator find this column by bot key
    f.dragName = entry.name
    f.dragClass = entry.class
    if activeTickKeys[key] then
        f.tickDot:Show()
    else
        f.tickDot:Hide()
    end

    local classColor = RAID_CLASS_COLORS and entry.class and RAID_CLASS_COLORS[entry.class]
    if classColor then
        f.name:SetTextColor(classColor.r, classColor.g, classColor.b)
    else
        f.name:SetTextColor(1, 1, 1)
    end
    NS.SetFittedName(f.name, entry.name)

    local iconCoords = entry.class and CLASS_ICON_COORDS[entry.class]
    if iconCoords then
        f.classIcon:SetTexCoord(iconCoords[1], iconCoords[2], iconCoords[3], iconCoords[4])
        f.classIconBtn:Show()
    else
        f.classIconBtn:Hide()
    end
    f.classIconBtn:SetScript("OnClick", function() NS.ToggleBotArmory(entry.name) end)
    f.classIconBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(entry.name, 1, 1, 1)
        GameTooltip:AddLine("Click to view armory", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f.classIconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Bags row: the inventory window ("сумка открывается при клике на инфу про
    -- сумки в табло").
    f.bagsBtn:SetScript("OnClick", function() NS.ToggleBotBags(entry.name) end)
    f.bagsBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(entry.name, 1, 1, 1)
        GameTooltip:AddLine("Click to view inventory", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f.bagsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Name row: the per-bot strategy window.
    f.nameBtn:SetScript("OnClick", function() NS.ToggleBotStrategy(entry.name) end)
    f.nameBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(entry.name, 1, 1, 1)
        GameTooltip:AddLine("Click to view strategy", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f.nameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Level row: the per-bot spellbook (cast a spell / make a macro for it).
    f.lvlBtn:Show()
    f.lvlBtn:SetScript("OnClick", function() NS.ToggleBotSpellbook(entry.name) end)
    f.lvlBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(entry.name, 1, 1, 1)
        GameTooltip:AddLine("Click to view spellbook", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f.lvlBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- XP row: the per-bot quest log.
    f.xpBtn:SetScript("OnClick", function() NS.ToggleBotQuestLog(entry.name) end)
    f.xpBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(entry.name, 1, 1, 1)
        GameTooltip:AddLine("Click to view quest log", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f.xpBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Top row: park/release this bot (Farm mode only, see NS.ToggleFarmHold); the
    -- top border mirrors entry.farmHeld.
    local inFarm = NS.EffectiveMode() == NS.MODE_FARM
    f.xpGainBtn:SetScript("OnClick", function() NS.ToggleFarmHold(key) end)
    f.xpGainBtn:SetScript("OnEnter", function(self)
        if not inFarm then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(entry.name, 1, 1, 1)
        GameTooltip:AddLine(entry.farmHeld and "Click to resume farming"
            or "Click to summon and stop farming", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f.xpGainBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    if inFarm and entry.farmHeld then f.holdBorder:Show() else f.holdBorder:Hide() end

    if entry.wild then
        f.xpGain:SetText("+0%")   -- a wild-class bot has no hourly gain; a fixed "+0%" keeps the rows aligned
    elseif entry.xpHourBase and entry.xpPercent then
        -- xpHourCarry banks the % earned on any level(s) finished earlier this hour;
        -- the current level's progress since its own baseline is added on top.
        -- Never negative - floor at 0.
        local gain = math.max(0, entry.xpPercent - entry.xpHourBase) + (entry.xpHourCarry or 0)
        f.xpGain:SetText("+" .. gain .. "%")
    else
        f.xpGain:SetText("--")
    end

    f.bags:SetText(entry.bagFree and (entry.bagFree .. "/" .. (entry.bagTotal or "?")) or "?")
    if entry.bagFree == 0 then
        f.bags:SetTextColor(1.0, 0.2, 0.2)
    elseif entry.bagFree and entry.bagFree <= 2 then
        f.bags:SetTextColor(1.0, 0.8, 0.2)
    elseif entry.bagFree then
        f.bags:SetTextColor(0.2, 1.0, 0.2)
    else
        f.bags:SetTextColor(0.6, 0.6, 0.6)
    end

    f.money:SetText(FormatMoney(entry.money))
    f.money:SetTextColor(1.0, 0.82, 0.0)

    f.xp:SetText(entry.xpPercent and (entry.xpPercent .. "%") or "?")
    f.xp:SetTextColor(0.8, 0.8, 1.0)

    f.lvl:SetText(entry.level and tostring(entry.level) or "?")
    f.lvl:SetTextColor(0.9, 0.9, 0.9)

    local stepLabel = STEP_LABEL[entry.step]
    if stepLabel then
        f.bags:SetText(stepLabel)
        f.bags:SetTextColor(0.4, 0.7, 1.0)
    end

    -- Highlight the column currently being serviced by the unload chain.
    if NS.active == key then
        f.activeGlow:Show()
    else
        f.activeGlow:Hide()
    end
    NS.ApplyColumnLayout(f)
end

--- Draws the master into board column `f`: the same rows as a bot, but every click
--- opens the standard game window (character, bags, talents, quest log) and there
--- is no tick indicator, hold border or step label.
local function FillMasterColumn(f)
    local entry = NS.masterEntry
    f.botKey = "__master"
    f.dragName = entry.name
    f.dragClass = entry.class
    f.tickDot:Hide()
    f.holdBorder:Hide()
    f.activeGlow:Hide()

    local classColor = RAID_CLASS_COLORS and entry.class and RAID_CLASS_COLORS[entry.class]
    if classColor then
        f.name:SetTextColor(classColor.r, classColor.g, classColor.b)
    else
        f.name:SetTextColor(1, 1, 1)
    end
    NS.SetFittedName(f.name, entry.name or "")

    local iconCoords = entry.class and CLASS_ICON_COORDS[entry.class]
    if iconCoords then
        f.classIcon:SetTexCoord(iconCoords[1], iconCoords[2], iconCoords[3], iconCoords[4])
        f.classIconBtn:Show()
    else
        f.classIconBtn:Hide()
    end

    local function wire(btn, label, onClick)
        btn:SetScript("OnClick", onClick)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(entry.name or "", 1, 1, 1)
            GameTooltip:AddLine(label, 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    wire(f.classIconBtn, "Character", function() ToggleCharacter("PaperDollFrame") end)
    wire(f.bagsBtn, "Bags", function() OpenAllBags() end)
    -- Name row: the GROUP strategy window - the same form as a bot's, applied to all bots
    -- (per explicit user direction). Talents will go on the level row once talent control
    -- of bots is figured out.
    wire(f.nameBtn, "Group strategy (applies to all bots)", function() NS.ToggleGroupStrategy() end)
    -- Level row: the master's own native spellbook
    wire(f.lvlBtn, "Spellbook", function()
        if SpellBookFrame:IsShown() then HideUIPanel(SpellBookFrame) else ShowUIPanel(SpellBookFrame) end
    end)
    wire(f.xpBtn, "Quest log", function()
        -- this client has no ToggleQuestLog(): open/close the native frame itself
        if QuestLogFrame:IsShown() then HideUIPanel(QuestLogFrame) else ShowUIPanel(QuestLogFrame) end
    end)
    f.xpGainBtn:SetScript("OnClick", nil)
    f.xpGainBtn:SetScript("OnEnter", nil)
    f.xpGainBtn:SetScript("OnLeave", nil)
    f.lvlBtn:Show()

    if entry.xpHourBase and entry.xpPercent then
        local gain = math.max(0, entry.xpPercent - entry.xpHourBase) + (entry.xpHourCarry or 0)
        f.xpGain:SetText("+" .. gain .. "%")
    else
        f.xpGain:SetText("--")
    end

    f.bags:SetText(entry.bagFree .. "/" .. entry.bagTotal)
    if entry.bagFree == 0 then
        f.bags:SetTextColor(1.0, 0.2, 0.2)
    elseif entry.bagFree <= 2 then
        f.bags:SetTextColor(1.0, 0.8, 0.2)
    else
        f.bags:SetTextColor(0.2, 1.0, 0.2)
    end
    f.money:SetText(FormatMoney(entry.money))
    f.money:SetTextColor(1.0, 0.82, 0.0)
    f.xp:SetText(entry.xpPercent and (entry.xpPercent .. "%") or "?")
    f.xp:SetTextColor(0.8, 0.8, 1.0)
    f.lvl:SetText(tostring(entry.level or "?"))
    f.lvl:SetTextColor(0.9, 0.9, 0.9)
    NS.ApplyColumnLayout(f)
end

-- ------------------------------------------------------------------
-- Drag & drop of a member (by the class icon of his column) from one raid group to another on
-- the board, per explicit user direction: dropped on a group with a free place -> he is moved there; on a full group ->
-- swapped with the member he is dropped on. Needs raid lead/assist (server side).
-- ------------------------------------------------------------------
-- The dragged column is shown as a translucent copy following the cursor (the original is
-- dimmed meanwhile).
NS.boardDragFrame = CreateFrame("Frame", nil, UIParent)
NS.boardDragFrame:SetSize(COL_WIDTH, ROW_HEIGHT * 6 + ICON_SIZE + TOP_PAD)
NS.boardDragFrame:SetFrameStrata("TOOLTIP")
NS.boardDragFrame:SetAlpha(0.85)
NS.boardDragFrame:Hide()
NS.boardDragFrame:SetScript("OnUpdate", function(self)
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
end)

--- Builds the ghost column once (a normal column, mouse off, taken out of the tick list).
NS.GetBoardGhost = function()
    if NS.boardGhost then return NS.boardGhost end
    local g = CreateColumn(NS.boardDragFrame)
    table.remove(NS.boardColumns)   -- not a real column: the tick indicators must not look it up
    g:ClearAllPoints()
    g:SetPoint("CENTER", NS.boardDragFrame, "CENTER", 0, 0)
    g:EnableMouse(false)
    for _, b in ipairs({ g.classIconBtn, g.xpGainBtn, g.bagsBtn, g.nameBtn, g.xpBtn, g.lvlBtn }) do b:EnableMouse(false) end
    g:Show()
    NS.boardGhost = g
    return g
end

NS.BoardDragStart = function(col)
    if GetNumRaidMembers() == 0 or not col.dragName then return end
    NS.boardDrag = { name = col.dragName, source = col }
    local g = NS.GetBoardGhost()
    NS.ApplyColumnLayout(g)
    for _, field in ipairs({ "xpGain", "name", "bags", "money", "xp", "lvl" }) do
        g[field]:SetText(col[field]:GetText())
        g[field]:SetTextColor(col[field]:GetTextColor())
    end
    g.classIcon:SetTexCoord(col.classIcon:GetTexCoord())
    if col.classIconBtn:IsShown() then g.classIconBtn:Show() else g.classIconBtn:Hide() end
    g.tickDot:Hide(); g.holdBorder:Hide(); g.activeGlow:Hide()
    col:SetAlpha(0.35)
    NS.boardDragFrame:Show()
    -- offer the first empty group as a drop target
    local groups = NS.ComputeBoardGroups()
    for idx = 1, 8 do
        if not groups[idx] or #groups[idx] == 0 then
            NS.boardDragExtra = idx
            break
        end
    end
    NS.RefreshPanel()
end

--- Moves raid member `name` into subgroup `target`: a plain move if it has a free place,
--- otherwise a swap with member `onto` (nil -> nothing happens).
NS.MoveRaidMember = function(name, target, onto)
    if not (IsRaidLeader() or IsRaidOfficer()) then
        Print("Moving raid members needs raid leader or assistant.")
        return
    end
    local byName, count = {}, {}
    for i = 1, GetNumRaidMembers() do
        local n, _, sub = GetRaidRosterInfo(i)
        if n then
            byName[strlower(n)] = { idx = i, sub = sub or 1 }
            count[sub or 1] = (count[sub or 1] or 0) + 1
        end
    end
    local src = byName[strlower(name)]
    if not src or src.sub == target then return end
    if (count[target] or 0) < 5 then
        SetRaidSubgroup(src.idx, target)
    elseif onto then
        local partner = byName[strlower(onto)]
        if partner and partner.sub == target then SwapRaidSubgroup(src.idx, partner.idx) end
    end
end

NS.BoardDragStop = function()
    local drag = NS.boardDrag
    NS.boardDrag = nil
    NS.boardDragFrame:Hide()
    if drag and drag.source then drag.source:SetAlpha(1) end
    if drag then
        local targetIdx, onto
        for idx, f in pairs(NS.boardFrames) do
            if f:IsShown() and f:IsMouseOver() then
                targetIdx = idx
                for _, col in ipairs(f.columns) do
                    if col:IsShown() and col.dragName and col:IsMouseOver() then onto = col.dragName end
                end
            end
        end
        if targetIdx then NS.MoveRaidMember(drag.name, targetIdx, onto) end
    end
    NS.boardDragExtra = nil
    NS.RefreshPanel()
    NS.After(0.6, function() NS.boardDirty = true end)   -- the roster update lands a moment later
end

-- Right click on a column: a menu with the same actions as the clicks on its rows (per explicit user direction),
-- opened under the cursor. A bot's column: its own windows; the master's: the standard game windows.
NS.boardMenu = CreateFrame("Frame", "AltBotBoardMenu", UIParent, "UIDropDownMenuTemplate")

NS.ShowBoardMenu = function(col)
    local master = col.botKey == "__master"
    local name = col.dragName
    if not name then return end
    local inFarm = NS.EffectiveMode() == NS.MODE_FARM
    local function native(frame)
        return function() if frame:IsShown() then HideUIPanel(frame) else ShowUIPanel(frame) end end
    end
    local items
    if master then
        items = {
            { text = "Armory", func = function() ToggleCharacter("PaperDollFrame") end },
            { text = "Strategies", func = function() NS.ToggleGroupStrategy() end },
            { text = "Inventory", func = function() OpenAllBags() end },
            { text = "Questlog", func = function() native(QuestLogFrame)() end },
            { text = "Spellbook", func = function() native(SpellBookFrame)() end },
        }
    else
        local key = col.botKey
        items = {}
        -- The first item exists only in Farm mode (per explicit user direction): "Summon" parks the bot next to
        -- the master, and for a bot that is already parked it reads "Free" (puts it back to work).
        if inFarm then
            local entry = NS.bots[key]
            items[#items + 1] = { text = (entry and entry.farmHeld) and "Free" or "Summon",
                func = function() NS.ToggleFarmHold(key) end }
        end
        for _, it in ipairs({
            { text = "Armory", func = function() NS.ToggleBotArmory(name) end },
            { text = "Strategies", func = function() NS.ToggleBotStrategy(name) end },
            { text = "Inventory", func = function() NS.ToggleBotBags(name) end },
            { text = "Questlog", func = function() NS.ToggleBotQuestLog(name) end },
            { text = "Spellbook", func = function() NS.ToggleBotSpellbook(name) end },
        }) do items[#items + 1] = it end
    end
    UIDropDownMenu_Initialize(NS.boardMenu, function()
        for _, item in ipairs(items) do
            local info = UIDropDownMenu_CreateInfo()
            info.notCheckable = true
            info.text = item.text
            info.disabled = item.disabled
            info.func = item.func
            UIDropDownMenu_AddButton(info)
        end
        local cancel = UIDropDownMenu_CreateInfo()
        cancel.notCheckable = true
        cancel.text = "Cancel"
        cancel.func = function() CloseDropDownMenus() end
        UIDropDownMenu_AddButton(cancel)
    end, "MENU")
    ToggleDropDownMenu(1, nil, NS.boardMenu, "cursor", 0, 0)
end

--- Redraws the whole board: which frames exist and what's in each column. Cheap
--- enough to call on every poll/reply/step.
NS.RefreshPanel = function()
    -- Solo means the whole roster is despawned (see NS.MODE_SOLO/DisbandRoster) and
    -- nothing polls it any more - every column's level/bags/money/XP would just sit
    -- frozen at whatever it last was before the disband, which reads as live data
    -- even though it's stale. Empty the board entirely instead; it repopulates
    -- itself the next time RefreshPanel runs after an explicit Summon/Free Roam
    -- click moves the mode away from Solo.
    local hideAll = NS.EffectiveMode() == NS.MODE_SOLO or not NS.boardReady
        or AltBot_SavedVars.panelShown == false
    if hideAll then
        for _, f in pairs(NS.boardFrames) do f:Hide() end
        return
    end

    NS.UpdateMasterEntry()
    local groups = NS.ComputeBoardGroups()

    for idx = 1, 8 do
        local members = groups[idx]
        if members and #members > 0 then
            local f = NS.GetBoardFrame(idx)
            NS.LayoutBoardFrame(f, #members)
            f:Show()
            for i, member in ipairs(members) do
                local col = f.columns[i]
                if member.master then
                    FillMasterColumn(col)
                else
                    FillBotColumn(col, member.key, NS.bots[member.key])
                    NS.PersistBotStats(NS.bots[member.key])
                end
            end
            if not f.positionChecked then
                f.positionChecked = true
                NS.EnsureBoardOnScreen(f)
            end
        elseif idx == NS.boardDragExtra then
            -- an empty group offered as a drop target while a member is being dragged
            local f = NS.GetBoardFrame(idx)
            NS.LayoutBoardFrame(f, 0)
            f:Show()
        elseif NS.boardFrames[idx] then
            NS.boardFrames[idx]:Hide()
        end
    end
end

--- A saved position can put a board frame fully off the screen this login has (seen
--- once in-game: the board silently ended up unreachable) - pull such a frame back.
NS.EnsureBoardOnScreen = function(f)
    local left, top = f:GetLeft(), f:GetTop()
    local right, bottom = f:GetRight(), f:GetBottom()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    if left and (right < 0 or left > sw or top < 0 or bottom > sh) then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 200 - ((f.idx - 1) % 5) * 128)
        if AltBot_SavedVars.boardPoints then AltBot_SavedVars.boardPoints[f.idx] = nil end
    end
end

-- ============================================================
-- Bot armory window — view-only, opened by clicking a bot's class icon in
-- the panel. Centered DressUpModel + paperdoll equip slots, ported from
-- CleanBot's Individual/Model.lua + Equip.lua (EQUIP_SLOTS layout data and
-- CB_SlotGeometry proportional sizing), simplified: no drag&drop/equip-by-
-- click/unequip menu (view-only, per original "только просмотр" scope),
-- and read directly via GetInventoryItemTexture/Link off the live group
-- unit — no NotifyInspect queue, since the bot is already grouped whenever
-- this window can be opened.
--
-- A fully independent per-bot window now (NS.botArmoryFrames /
-- GetOrCreateArmoryFrame / NS.ToggleBotArmory), same pattern as the bags
-- window above — per explicit user direction: "старый фрейм должен стать
-- фреймом армори для каждого бота свой, ничего другого в нем не должно
-- быть". The old shared frame's right-side Combat/Non-Combat/Quest switch
-- panel has been removed entirely from this window (strategy/quest-log will
-- each get their own standalone per-bot window in a later pass) — this
-- window is model+equip only. The old Bags tab here was already removed
-- earlier — superseded by the independent per-bot bags window
-- (NS.ToggleBotBags / GetOrCreateBagsFrame further above).
-- ============================================================

-- Equipment slot layout — mirrors CleanBot's Individual/EquipData.lua
-- (NS.EQUIP_SLOTS / NS.CB_SlotGeometry), trimmed of nothing since the data
-- itself has no CleanBot-specific dependencies.
local EQUIP_SLOTS = {
    { id=1,  name="Head",      side="left",   order=1, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Head"          },
    { id=2,  name="Neck",      side="left",   order=2, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Neck"          },
    { id=3,  name="Shoulder",  side="left",   order=3, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Shoulder"      },
    { id=15, name="Back",      side="left",   order=4, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest"          },
    { id=5,  name="Chest",     side="left",   order=5, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest"         },
    { id=4,  name="Shirt",     side="left",   order=6, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Shirt"         },
    { id=19, name="Tabard",    side="left",   order=7, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Tabard"        },
    { id=9,  name="Wrist",     side="left",   order=8, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Wrists"        },
    { id=10, name="Hands",     side="right",  order=1, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Hands"         },
    { id=6,  name="Waist",     side="right",  order=2, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Waist"         },
    { id=7,  name="Legs",      side="right",  order=3, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Legs"          },
    { id=8,  name="Feet",      side="right",  order=4, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Feet"          },
    { id=11, name="Finger 1",  side="right",  order=5, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger"        },
    { id=12, name="Finger 2",  side="right",  order=6, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger"        },
    { id=13, name="Trinket 1", side="right",  order=7, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"       },
    { id=14, name="Trinket 2", side="right",  order=8, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"       },
    { id=16, name="Main Hand", side="bottom", order=1, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand"      },
    { id=17, name="Off Hand",  side="bottom", order=2, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand" },
    { id=18, name="Ranged",    side="bottom", order=3, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Ranged"        },
    { id=0,  name="Ammo",      side="bottom", order=4, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Ammo"          },
}

-- Paperdoll geometry of the native 3.3.5 character frame (PaperDollFrame),
-- in its own units: 37px slots with a 4px gap, a 231x320 model between the two
-- slot columns, the weapon row starting 413px below the frame top, and the
-- Ammo slot at the end of that row. The armory window is laid out on exactly
-- this grid - per explicit user direction ("верстка армори 1 в 1 как у родной
-- близардовской формы персонажа"). The original XML is packed in the client's
-- MPQs, so these numbers come from the known 3.3.5 layout checked against a
-- screenshot of the real frame; tweak here if a spot is off by a few pixels.
local PD = {
    slot     = 37,
    step     = 37 + 4,     -- slot + 4px gap, between stacked slots
    frameW   = 343,
    frameH   = 423,
    headerH  = 60,         -- name/subtitle band above the first slot row (the native 76 minus half of the empty space under the subtitle)
    leftX    = 10,
    rightX   = 343 - 9 - 37,
    modelX   = 55,
    modelW   = 231,
    modelH   = 320,
    weaponY  = 370,
    weaponX  = { 111, 157, 203, 253 },   -- MainHand, OffHand, Ranged, Ammo
    ammoSlot = 28,         -- the Ammo slot is drawn smaller than the others (per explicit user direction)
}
-- Bottom of the GS/iLevel and spec/talents text lines, measured up from the model's
-- bottom edge: 8 units above the weapon row (which now overlaps the model's lower
-- edge, like the native frame's stat panels do).
PD.textY = (PD.headerH + PD.modelH) - (PD.weaponY - 8)


local ITEM_CELL_SIZE = 37
local ITEM_CELL_PAD  = 3
-- 40 was not actually a generous-enough upper bound — confirmed by the user
-- in-game: a bot with 4 bags (bagTotal 44) had no cells at all for slots
-- 41-44, since this constant caps how many cell OBJECTS the frame creates in
-- the first place, not just how many it shows. 136 = backpack (16) + 4x
-- Portable Hole (30 slots each, a real purchasable item, not a custom/
-- private-server bag) — the real practical maximum. 17 rows of 8 exactly.
local ITEM_MAX_SLOTS = 136   -- generous upper bound; actual bagTotal trims the shown grid

--- One raw "items" reply line -> a single { link, count } entry, shown as
--- ONE grid cell with its reported total count, no matter how large. A
--- previous version tried to split a total exceeding GetItemInfo's maxStack
--- into multiple maxStack-sized cells (on the theory that a stack over the
--- limit must really span several slots) — dropped per explicit user
--- direction: GetItemInfo's maxStack guess is wrong for plenty of items (e.g.
--- reports 60 for a cloth type whose real per-stack limit on this server is
--- 90), so splitting on it produces a WRONG number of cells just as often as
--- it "fixes" one. Showing the server's own total as a single cell (same as
--- Bagnon does, per the user's own reference screenshot) is honest about
--- what we actually know and doesn't fabricate a slot count we can't verify.
local function ParseItemLine(raw)
    local link = raw:match("(|c%x+|Hitem:[^|]+|h%[.-%]|h|r)")
    if not link then return nil end
    local count = tonumber(raw:match("|r%s*x(%d+)")) or 1
    return { link = link, count = count }
end

-- ============================================================
-- Bags window — a fully independent, per-bot frame (NOT a tab/section of
-- the shared detail window further below). Per explicit user direction:
-- "реализуем показ сумок для каждого бота в своем фрейме как у cleanbot" /
-- "должен быть отдельный фрейм только с сумкой" / "старого фрейма вообще
-- потом не будет, все фреймы будут отдельно" — the big shared detail
-- window (model+equip+strategy+bags+quests all as switchable sections of
-- ONE frame) is being replaced piece by piece with independent per-bot
-- windows, one per kind of data; this is the first of them. Verstka
-- (layout) mirrors CleanBot's own bag window 1:1 — see Individual/
-- Inventory.lua's CB_GetGridFrame/CB_RenderInventory: ItemButtonTemplate
-- cells in a fixed-column grid, a title bar, a slot-count/money footer, and
-- a close button — just without CleanBot's drag&drop/bank/equip features,
-- which weren't asked for initially (per explicit user direction: "сейчас
-- только меню+тултип, drag&drop позже") — drag&drop for REORDERING items
-- within the same bag (no server commands, no trade-window integration) was
-- added later; see NS.BeginBagsCellDrag/NS.EndBagsCellDrag below.
-- ============================================================
NS.botBagsFrames = NS.botBagsFrames or {}   -- lower(name) -> frame, created lazily on first open

--- Remembers a per-bot window's position across /reload (account-wide, per window kind and
--- bot): restores the saved spot now and saves a new one when a drag ends - per explicit
--- user direction ("запоминай расположение фреймов армори, сумок, стратегии, квестлога для
--- каждого бота"). Call right after the frame got its default SetPoint and is movable.
NS.RememberWindowPosition = function(f, kind, botName)
    local key = strlower(botName)
    local saved = AltBot_SavedVars and AltBot_SavedVars.windowPoints
        and AltBot_SavedVars.windowPoints[kind] and AltBot_SavedVars.windowPoints[kind][key]
    -- Only trust a saved spot that is still within this screen.
    if saved and math.abs(saved[3] or 0) <= UIParent:GetWidth() and math.abs(saved[4] or 0) <= UIParent:GetHeight() then
        f:ClearAllPoints()
        f:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    end
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        AltBot_SavedVars = AltBot_SavedVars or {}
        AltBot_SavedVars.windowPoints = AltBot_SavedVars.windowPoints or {}
        AltBot_SavedVars.windowPoints[kind] = AltBot_SavedVars.windowPoints[kind] or {}
        AltBot_SavedVars.windowPoints[kind][key] = { point, relPoint, x, y }
    end)
end

local BAGS_COLS = 8
--- Builds (once per bot) or returns the existing bags window for `botName`.
--- Each bot gets its OWN frame — unlike the old shared detail window, two
--- bots' bag windows can be open side by side at once.
local function GetOrCreateBagsFrame(botName)
    local key = strlower(botName)
    local f = NS.botBagsFrames[key]
    if f then return f end

    -- SetHeight is NOT optional here — a frame with only SetWidth (no
    -- SetHeight) never gets a real height in this client, so it renders as
    -- a zero-height sliver even after :Show() (confirmed by the user
    -- in-game: nothing appeared on click). Height = header + grid rows +
    -- footer.
    local rows = math.ceil(ITEM_MAX_SLOTS / BAGS_COLS)
    local frameW = 12 + BAGS_COLS * (ITEM_CELL_SIZE + ITEM_CELL_PAD) - ITEM_CELL_PAD + 12
    local frameH = 40 + rows * (ITEM_CELL_SIZE + ITEM_CELL_PAD) - ITEM_CELL_PAD + 30
    f = CreateFrame("Frame", "AltBotBags_" .. key, UIParent)
    f.botName = botName
    f:SetWidth(frameW)
    f:SetHeight(frameH)
    -- A brand-new frame has no anchor at all until one is set — without
    -- this it has undefined screen position (confirmed by the user in-game
    -- alongside the missing SetHeight above: the frame existed and was
    -- shown, but nowhere visible on screen). Center by default; the
    -- OnDragStop below doesn't persist position per-bot (out of scope for
    -- now — every bot's bags window reopens centered).
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    NS.RememberWindowPosition(f, "bags", botName)
    -- Raise this bot's window above every other bags window on click — per
    -- explicit user direction ("активный фрейм должен быть поверх всех
    -- остальных"). SetToplevel above already does this automatically for
    -- mouse-down anywhere on the frame; OnMouseDown covers clicks on
    -- non-mouse-enabled children (e.g. the FontStrings) that wouldn't
    -- otherwise trigger it.
    f:SetScript("OnMouseDown", function(self) self:Raise() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 12, bottom = 11 },
    })
    -- UI-DialogBox-Background is semi-transparent by design (retail dialogs
    -- layer it over 3D world content on purpose) — explicit opaque black
    -- backdrop color per explicit user direction ("фреймы сумок не должны
    -- быть прозрачными"), so one bot's bags window fully occludes whatever
    -- is behind it (world or another bot's window).
    f:SetBackdropColor(0, 0, 0, 1)

    -- Title bar
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText(botName .. "'s Inventory")
    f.title = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    -- Re-syncs with the server on close, not after each action — per
    -- explicit user direction ("запрос апдейта происходит в момент закрытия
    -- окна сумки"). Still diff-merges into the persistent cache rather than
    -- overwriting it outright, so the user's own drag&drop ordering survives
    -- this close-triggered refresh (see MergeBagsUpdate's own doc comment).
    -- NS.ToggleBotBags' own close branch (board-column click while already
    -- open) does the same; this is the OTHER way to close the window (the ×
    -- button), so it needs its own copy of that refresh.
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        NS.RefreshBotBagsItems(botName)
        NS.bagsSessionSoldLinks[strlower(botName)] = nil
    end)

    -- Item cell grid
    f.cells = {}
    local firstCell
    for i = 1, ITEM_MAX_SLOTS do
        local row = math.floor((i - 1) / BAGS_COLS)
        local col = (i - 1) % BAGS_COLS

        local cellName = "AltBotBagsCell_" .. key .. "_" .. i
        local cell = CreateFrame("Button", cellName, f, "ItemButtonTemplate")
        cell:SetSize(ITEM_CELL_SIZE, ITEM_CELL_SIZE)
        if not firstCell then
            cell:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -40)
            firstCell = cell
        else
            cell:SetPoint("TOPLEFT", firstCell, "TOPLEFT",
                col * (ITEM_CELL_SIZE + ITEM_CELL_PAD), -row * (ITEM_CELL_SIZE + ITEM_CELL_PAD))
        end

        cell.icon = _G[cellName .. "IconTexture"]
        cell.icon:Hide()
        cell.countText = _G[cellName .. "Count"]
        cell.countText:Hide()

        -- Item border — colored by quality (Uncommon green / Rare blue /
        -- Epic purple / etc, via GetItemQualityColor) or gold for quest
        -- items (overrides quality — see NS.ApplyItemBorder below). Same
        -- SetBackdrop/edgeFile approach the action bar's own "active" ring
        -- already uses (CreateActionIconButton's `border`), confirmed
        -- working in-game, instead of guessing at ItemButtonTemplate's own
        -- built-in regions again.
        cell.border = CreateFrame("Frame", nil, cell)
        cell.border:SetAllPoints(cell)
        cell.border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
        cell.border:Hide()

        cell.slotIndex = i
        cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        cell:SetScript("OnClick", function(self, button)
            if IsShiftKeyDown() then
                NS.InsertLinkIntoChat(self.itemLink)
                return
            end
            if button == "RightButton" then
                NS.ShowItemCellMenu(self)
            else
                NS.TradeCellItem(self)
            end
        end)
        cell:SetScript("OnEnter", function(self)
            if not self.itemLink then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end)
        cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Drag-and-drop REORDERING within this same bag only (no server
        -- commands, no trade-window integration — per explicit user
        -- direction: "дело за малым, сделать drag&&drop в сумке" / "пока
        -- только в пределах сумки"). WoW's own Button widget tells apart a
        -- plain click (OnClick above) from an actual drag (OnDragStart/Stop
        -- below) based on real mouse movement past a small threshold, so
        -- both can coexist on the same button without any extra bookkeeping
        -- for "was this really a drag or just a click".
        cell:RegisterForDrag("LeftButton")
        cell:SetScript("OnDragStart", function(self)
            if not self.itemLink then return end
            NS.BeginBagsCellDrag(self)
        end)
        cell:SetScript("OnDragStop", function(self)
            NS.EndBagsCellDrag(self)
        end)
        cell:SetScript("OnReceiveDrag", function(self)
            NS.EndBagsCellDrag(self)
        end)
        cell:Hide()

        f.cells[i] = cell
    end

    -- Footer: slot count, Sell | Trade, money — the Sell/Trade halves pick
    -- what a left-click on an item cell actually does (see
    -- NS.TradeCellItem's own doc comment for how it reads this).
    local slotLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slotLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 14)
    f.slotLabel = slotLabel

    local moneyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moneyLabel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 14)
    f.moneyLabel = moneyLabel

    f.leftClickMode = "sell"   -- "trade" | "sell" — which NS.TradeCellItem/left-click does; sell is default

    -- No slider any more — the footer is split in two halves, per explicit
    -- user direction: left half = slot count (left edge) + "Sell" (right
    -- edge, against the middle); right half = "Trade" (left edge, against
    -- the middle) + money (right edge). A click anywhere on the left half
    -- makes Sell the left-click default, on the right half Trade.
    local sellLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sellLabel:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -8, 14)
    sellLabel:SetText("Sell")

    local tradeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tradeLabel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 8, 14)
    tradeLabel:SetText("Trade")

    --- Active side's label white, the other gold (same recolor as before).
    local function RefreshToggle()
        if f.leftClickMode == "sell" then
            sellLabel:SetTextColor(1, 1, 1)
            tradeLabel:SetTextColor(1.0, 0.82, 0.0)
        else
            sellLabel:SetTextColor(1.0, 0.82, 0.0)
            tradeLabel:SetTextColor(1, 1, 1)
        end
    end
    f.RefreshLeftClickToggle = RefreshToggle

    local sellHit = CreateFrame("Button", nil, f)
    sellHit:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 8)
    sellHit:SetPoint("TOPRIGHT", f, "BOTTOM", 0, 28)
    sellHit:SetScript("OnClick", function()
        f.leftClickMode = "sell"
        RefreshToggle()
    end)

    local tradeHit = CreateFrame("Button", nil, f)
    tradeHit:SetPoint("BOTTOMLEFT", f, "BOTTOM", 0, 8)
    tradeHit:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -8, 28)
    tradeHit:SetScript("OnClick", function()
        f.leftClickMode = "trade"
        RefreshToggle()
    end)

    RefreshToggle()

    f:Hide()
    NS.botBagsFrames[key] = f
    return f
end

--- Renders `items`/`bagTotal`/`money` into `botName`'s OWN bags frame — does
--- NOT touch any other bot's window, unlike the old shared detail frame's
--- now-removed bags tab (which needed an "only if this frame is bound to
--- THIS bot" guard purely because one frame served every bot; that whole
--- class of bug is structurally impossible here since each bot has its own
--- frame). Only paints if the frame has actually been created (i.e. the
--- user has opened it at least once) — never creates one just to fill it in
--- the background.
--- Paints whatever `items` currently holds straight away — no staged
--- skeleton-then-final sequencing, no reconciling against a separate stats
--- reply. Per explicit user direction ("не нужно своего stats... не нужно
--- никаких перерасчетов, показываем так как приходит в items"): keep this
--- dumb — just render the list as-is, sized to bagTotal (borrowed from the
--- roster's own background stats poll, NS.bots[key]).
local function PaintBagsFrame(botName, items, bagTotal, bagFree, money)
    local key = strlower(botName)
    local f = NS.botBagsFrames[key]
    if not f then return end

    -- Resize the frame to fit exactly this bot's own slot count instead of
    -- always showing a fixed ITEM_MAX_SLOTS-worth of rows — per explicit
    -- user direction ("нужно верстать сумку по количеству всего ячеек с
    -- показом пустых слотов как здесь", pointing at CleanBot's own bag
    -- window, which sizes its grid to the bot's real total instead of a
    -- flat maximum). Falls back to the full ITEM_MAX_SLOTS grid only when
    -- bagTotal isn't known yet.
    local shownSlots = bagTotal or ITEM_MAX_SLOTS
    local shownRows = math.max(1, math.ceil(shownSlots / BAGS_COLS))
    f:SetHeight(40 + shownRows * (ITEM_CELL_SIZE + ITEM_CELL_PAD) - ITEM_CELL_PAD + 30)

    for i, cell in ipairs(f.cells) do
        local item = items[i]
        if item then
            local itemId = item.link:match("item:(%d+)")
            cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            cell.icon:SetTexture(itemId and GetItemIcon(tonumber(itemId)) or nil)
            cell.icon:Show()
            cell.itemLink = item.link
            if item.count > 1 then
                cell.countText:SetText(item.count)
                cell.countText:Show()
            else
                cell.countText:Hide()
            end
            NS.ApplyItemBorder(cell, item.link)
            cell:Show()
        else
            -- Standard Blizzard empty-backpack-slot art (per the user's own
            -- Bagnon reference screenshot — a dark textured square, not just
            -- an empty transparent cell). Full 0-1 texcoord: this is a
            -- complete square asset, not a zoomed-in item icon, so it must
            -- NOT get the 0.08-0.92 crop used for real item icons above.
            cell.icon:SetTexCoord(0, 1, 0, 1)
            cell.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
            cell.icon:Show()
            cell.itemLink = nil
            cell.countText:Hide()
            NS.ApplyItemBorder(cell, nil)
            if i <= shownSlots then
                cell:Show()
            else
                cell:Hide()
            end
        end
    end

    -- Same "free/total" format as the stats board's own bags column (see
    -- NS.RefreshPanel's f.bags:SetText(entry.bagFree .. "/" .. bagTotal)) —
    -- per explicit user direction: "формат пустых и всего ячеек должен быть
    -- как в табло пустые/всего". Not "used/total" — bagFree is what the
    -- board shows, and this window should read the same way at a glance.
    --
    -- bagFree is recomputed HERE from the actual item cache, not taken
    -- as-is from the server's own "stats" number — per explicit user
    -- direction ("верни назад в сумке показ количества пустых слотов,
    -- которые реально получаются в математике сумки"). This was tried
    -- before and reverted when MergeBagsUpdate itself had a bug (holes from
    -- earlier merges were invisible to the tail-overflow check, silently
    -- dropping new items so the cache undercounted); now that the merge
    -- always rebuilds its hole list from actual cache contents and fills
    -- holes before the tail, the cache's own count is reliable again.
    if bagTotal then
        local occupied = 0
        for i = 1, bagTotal do
            if items[i] then occupied = occupied + 1 end
        end
        f.slotLabel:SetText((bagTotal - occupied) .. "/" .. bagTotal)
    else
        f.slotLabel:SetText("?/?")
    end
    if money then
        f.moneyLabel:SetText(FormatMoneyFull(money))
    else
        f.moneyLabel:SetText("")
    end
end

-- ============================================================
-- Drag-and-drop item reordering WITHIN one bot's own bag — swaps two slots'
-- positions in the persistent cache (AltBot_SavedVars.bagsCache), purely a
-- local display reorganization with no server command involved at all. Per
-- explicit user direction ("дело за малым, сделать drag&&drop в сумке" /
-- "пока только в пределах сумки"). Uses the same SetCursor(iconPath)/
-- ResetCursor approach CleanBot's own drag system uses (Individual/
-- Inventory.lua) to show the dragged item's icon on the cursor — there's no
-- real ContainerFrame/PickupContainerItem backing these virtual cells, so
-- this is the standard way to get that visual feedback anyway.
-- ============================================================
local bagsDrag = nil   -- { f = frame, fromIndex = number, link = string } | nil

--- Begins dragging the item in `cell` — remembers the source slot, dims its
--- icon, and puts that item's icon on the cursor.
NS.BeginBagsCellDrag = function(cell)
    local f = cell:GetParent()
    if not f or not f.botName then return end
    bagsDrag = { f = f, fromIndex = cell.slotIndex, link = cell.itemLink }
    cell.icon:SetDesaturated(true)
    local itemId = strmatch(cell.itemLink, "item:(%d+)")
    SetCursor(GetItemIcon(tonumber(itemId) or 0))
end

--- Ends a drag — WoW always fires OnDragStop on the SOURCE button (the one
--- OnDragStart was called on), with `self` still the source cell, regardless
--- of where the mouse was released; it's NOT called on whatever's underneath
--- the cursor the way a real OnReceiveDrag would be, since SetCursor() never
--- puts an actual "cursor item" on the cursor (CursorHasItem() stays false,
--- so Blizzard never fires OnReceiveDrag for us either — that handler is
--- wired up but realistically dead code here). So the actual drop target has
--- to be found explicitly via GetMouseFocus() at release time — the frame
--- directly under the mouse right now — same technique CleanBot's own
--- virtual-cursor drag system uses it own way (OnUpdate hit-testing) for the
--- same underlying reason.
NS.EndBagsCellDrag = function(cell)
    if not bagsDrag then return end
    local drag = bagsDrag
    bagsDrag = nil
    ResetCursor()

    -- Undim the source cell's icon regardless of outcome — PaintBagsFrame
    -- (called below on a successful swap) would also reset this, but a
    -- cancelled/invalid drop never reaches that repaint otherwise.
    local sourceCell = drag.f.cells[drag.fromIndex]
    if sourceCell then sourceCell.icon:SetDesaturated(false) end

    local target = GetMouseFocus()
    if not target or not target.slotIndex then return end   -- dropped on empty space — cancel
    local targetF = target:GetParent()
    if targetF ~= drag.f then return end   -- dropped outside this bag entirely — cancel
    local toIndex = target.slotIndex
    if not toIndex or toIndex == drag.fromIndex then return end   -- dropped on itself/invalid — cancel

    local key = strlower(drag.f.botName)
    local cache = AltBot_SavedVars.bagsCache[key]
    if not cache then return end

    cache[drag.fromIndex], cache[toIndex] = cache[toIndex], cache[drag.fromIndex]
    local maxIndex = math.max(drag.f.itemsMaxIndex or 0, toIndex, drag.fromIndex)
    drag.f.itemsMaxIndex = maxIndex

    local rosterEntry = NS.bots[key]
    PaintBagsFrame(drag.f.botName, cache,
        rosterEntry and rosterEntry.bagTotal,
        rosterEntry and rosterEntry.bagFree,
        rosterEntry and rosterEntry.money)
end

-- ============================================================
-- Bags window's OWN "items" fetch, backed by a PERSISTENT per-bot cache
-- (AltBot_SavedVars.bagsCache[key]) — per explicit user direction ("все
-- содержимое сумок должно храниться в кэше бота ... этот кэш должен
-- пережить /reload"): survives /reload and switching masters, same as
-- rosterText/mode, unlike NS.bots (which is rebuilt from scratch every
-- session). No own "stats" whisper — bagTotal/bagFree/money are read
-- straight off the roster's own background "stats" poll (NS.bots[key]).
--
-- Opening the window paints the cache INSTANTLY, then fires a background
-- "items" fetch; when that reply lands, the grid is NOT simply redrawn from
-- scratch — unchanged items keep their slot, newly-appeared items are
-- appended at the end, and items that vanished are holed out in place (per
-- explicit user direction: "не просто перерисовывать всю сумку, а в конец
-- добавить те шмотки которые появились и дырками удалить те шмотки которых
-- не стало"). See MergeBagsUpdate below for the actual diff.
--
-- A bot's own Trade/Sell/Deposit/Destroy actions while the window is open
-- are remembered in bagsSessionSoldLinks (in-memory only, reset fresh each
-- time the window opens) so a background "items" reply that still lists an
-- item the master already got rid of this session doesn't resurrect it (per
-- explicit user direction: "за время когда открылось окно сумок и пришли
-- обновления, мастер мог успеть продать/отдать часть шмоток ... эти шмотки
-- на момент пришедшего обновления в сумку возвращать не нужно"). On CLOSE,
-- the final "items" reply is authoritative — it fully overwrites the cache
-- with no diffing/filtering at all (per explicit user direction: "любые
-- коллизии решатся в моменте закрытия окна сумок и в кэши будет
-- окончательный правильный вариант с сервера").
-- ============================================================
-- AltBot_SavedVars.bagsCache is initialized in the ADDON_LOADED handler
-- further below (loader:SetScript), NOT here at top level — top-level code
-- in this file runs while the file is first being parsed, which is BEFORE
-- the game engine applies the real saved AltBot_SavedVars table from disk
-- over the global of the same name; initializing bagsCache here would get
-- silently discarded the moment the real saved data replaces this file's
-- temporary `AltBot_SavedVars = AltBot_SavedVars or {}` placeholder
-- (confirmed by the user in-game: "attempt to index field 'bagsCache' (a nil
-- value)" the very first time a bags window was opened after a fresh login).

local bagsItemsAwaiting = {}      -- lower(name) -> { items = {}, timer = number }
NS.bagsItemsAwaiting = bagsItemsAwaiting   -- read by the chat classifier
-- NS. field (not local) — GetOrCreateBagsFrame's close button, defined
-- earlier in the file than this section, needs to reference it; a `local`
-- declared here would compile as a global there instead (Lua resolves
-- locals lexically at compile time — a local declared LATER is never
-- visible to code written earlier, even though that earlier code only
-- actually runs much later, same forward-reference pitfall as
-- NS.EffectiveMode's own doc comment describes elsewhere in this file).
NS.bagsSessionSoldLinks = {}   -- lower(name) -> { [link] = true } while that bot's window is open this session

local bagsItemsWatcher = CreateFrame("Frame")
bagsItemsWatcher:RegisterEvent("CHAT_MSG_WHISPER")
bagsItemsWatcher:SetScript("OnEvent", function(self, event, msg, sender)
    local key = strlower(sender or "")
    local collecting = bagsItemsAwaiting[key]
    if not collecting then return end
    -- Opening a TRADE with the bot (right-click Trade) makes it whisper its tradeable
    -- items, grouped under "--- other ---"/"--- consumable ---"/... headers: the whole
    -- inventory a second time, item links and all. If that arrives while an "items"
    -- fetch is still collecting, it must NOT be taken for part of the listing (the
    -- bags window showed every item twice after a trade): everything after such a
    -- header is ignored until the real listing's "=== Inventory ===" header comes again.
    local plain = NS.CleanEscapes(msg)
    local header = plain:match("^%-%-%- (.+) %-%-%-$")
    if header then
        collecting.category = strlower(header)
        collecting.ignoreLines = true
    elseif plain:find("=== Inventory ===", 1, true) then
        collecting.ignoreLines = false
    end
    if not collecting.ignoreLines and strfind(msg, "|Hitem:", 1, true) then
        local item = ParseItemLine(msg)
        if item then
            item.category = collecting.category
            collecting.items[#collecting.items + 1] = item
        end
    end
    collecting.timer = 0
    -- Same chat-hiding re-extension the tracked-roster "items" collector
    -- uses (see its own doc comment) — SendBotCommand's STEP_DELAY block
    -- window is shorter than this collector's own silence timeout.
    NS.blockedBotNames[key] = true
    NS.After(NS.STATS_TIMEOUT, function() NS.blockedBotNames[key] = nil end)
end)

--- "System shout", chat only (no on-screen text) per explicit user direction,
--- in the game's own "<Name>: Failed to cast ..." error format: the bot's name
--- yellow, the colon and message red.
NS.SystemShout = function(name, text)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00" .. name .. "|r|cffff0000: " .. text .. "|r")
end

local SUPPLY_ALERT_REPEAT = 300   -- seconds between repeats of the same alert while it stays true
local supplyAlertAt = {}          -- key..":"..kind -> GetTime() of the last shout

--- Checks a fresh "items" list for the class-specific supplies a bot can't do
--- without and shouts when one is missing (per explicit user direction):
---   Hunter -> any ammo ("projectile" listing section) else "<Name>: нет боеприпасов!"
---   Rogue  -> any poison (a consumable named ...Poison/...яд...) else "<Name>: нет ядов!"
--- Re-shouts every SUPPLY_ALERT_REPEAT seconds while still missing, and
--- starts over as soon as the item shows up again. NOTE: only bag contents
--- are listed — ammo already sitting in the ammo slot isn't visible here.
--- Classifies one listed item from the client's own item data (the bot's
--- plain "items" reply carries NO category headers — those only appear in the
--- trade list). Returns name, itemType, subType (nil if the client doesn't
--- have the item cached yet; the link text still gives a name then).
NS.SupplyItemInfo = function(link)
    local name, _, _, _, _, itemType, subType = GetItemInfo(link)
    return name or (link and link:match("%[(.-)%]")) or "", itemType, subType
end

NS.AMMO_WORDS = { "arrow", "shot", "bullet", "slug", "bolt", "shell", "стрел", "пул", "патрон", "дробь" }
NS.IsAmmoItem = function(name, itemType, subType)
    if itemType or subType then
        local classes = { GetAuctionItemClasses() }
        if itemType == "Projectile" or itemType == "Боеприпасы" or (classes[7] and itemType == classes[7])
            or subType == "Arrow" or subType == "Bullet" or subType == "Стрелы" or subType == "Пули" then
            return true
        end
        if itemType then return false end   -- known type, and it isn't ammo
    end
    local lower = strlower(name)
    for _, w in ipairs(NS.AMMO_WORDS) do
        if strfind(lower, w, 1, true) then return true end
    end
    return false
end

NS.IsPoisonItem = function(name)
    return strfind(strlower(name), "poison", 1, true) ~= nil
        or strfind(name, "Яд ", 1, true) ~= nil or strfind(name, " яд", 1, true) ~= nil
        or strfind(name, "яд ", 1, true) ~= nil or name:match("яд$") ~= nil
end

NS.supplyDebugState = {}   -- key -> last debug state printed (only changes are printed)
NS.SupplyDebug = function(entry, state, text)
    if NS.supplyDebugState[entry.name] == state then return end
    NS.supplyDebugState[entry.name] = state
    Print("[Supplies] " .. entry.name .. ": " .. text)
end

NS.CheckBotSupplies = function(key, items)
    local entry = NS.bots[key]
    if not entry or not entry.class then return end
    -- Only a COMPLETE listing proves anything is missing. A partial one (the
    -- reply cut short — seen in-game: 4 items listed for a bot holding 39)
    -- would shout false alarms, so compare with how many slots the roster's own
    -- "stats" says are occupied and skip anything clearly short of that.
    if entry.class == "HUNTER" or entry.class == "ROGUE" then
        if #items == 0 or not entry.bagTotal or not entry.bagFree then
            NS.SupplyDebug(entry, "skip-nodata", "check skipped, no complete data yet (items " .. #items .. ")")
            return
        end
        local occupied = entry.bagTotal - entry.bagFree
        if #items < occupied * 0.8 then
            NS.SupplyDebug(entry, "skip-partial", string.format("check skipped, partial list (%d items of %d occupied slots)", #items, occupied))
            return
        end
    end
    if #items == 0 or not entry.bagTotal or not entry.bagFree then return end
    local occupied = entry.bagTotal - entry.bagFree
    if #items < occupied * 0.8 then return end

    local function check(kind, missingText, hasIt)
        local id = key .. ":" .. kind
        if hasIt then
            supplyAlertAt[id] = nil
            return
        end
        local now = GetTime()
        if not supplyAlertAt[id] or now - supplyAlertAt[id] >= SUPPLY_ALERT_REPEAT then
            supplyAlertAt[id] = now
            NS.SystemShout(entry.name, missingText)
            -- Diagnostic for a false alarm: what the check actually saw.
            local seen = {}
            for i = 1, math.min(#items, 6) do
                local name, itemType, subType = NS.SupplyItemInfo(items[i].link)
                seen[#seen + 1] = name .. "(" .. tostring(itemType) .. "/" .. tostring(subType) .. ")"
            end
            Print(string.format("[Supplies] %s: %d items, first: %s", entry.name, #items, table.concat(seen, ", ")))
        end
    end

    if entry.class == "HUNTER" then
        local has = false
        for _, item in ipairs(items) do
            if item.category == "projectile" or NS.IsAmmoItem(NS.SupplyItemInfo(item.link)) then
                has = true
                local name, itemType, subType = NS.SupplyItemInfo(item.link)
                NS.SupplyDebug(entry, "ammo:" .. name, string.format("ammo found: %s (%s/%s, category %s)",
                    name, tostring(itemType), tostring(subType), tostring(item.category)))
                break
            end
        end
        if not has then NS.SupplyDebug(entry, "noammo", "no ammo among " .. #items .. " items") end
        check("ammo", "нет боеприпасов!", has)
    elseif entry.class == "ROGUE" then
        local has = false
        for _, item in ipairs(items) do
            local name = NS.SupplyItemInfo(item.link)
            if NS.IsPoisonItem(name) then has = true; break end
        end
        check("poison", "нет ядов!", has)
    end
end

--- Merges a fresh "items" list from the server into the persistent cache
--- IN PLACE: items still present keep their existing slot, and cached items
--- that no longer appear in freshItems get holed out (set to nil) — UNLESS
--- they're in soldLinks (something this session's own Trade/Sell/Deposit/
--- Destroy already removed locally; the server simply hasn't caught up yet,
--- so leave that hole as the optimistic removal already left it rather than
--- touching it again). Newly-seen items (not already in the cache, by link)
--- fill the FIRST available hole (ascending index) first, and only once
--- every hole is filled do they get appended after the current highest
--- occupied index. Per explicit user direction: "удаляем те, что не стало,
--- оставляя дырки, добавляем новые не в конец, а с первой дырки" — holes
--- take priority over the tail (the reverse of this function's earlier
--- tail-first behavior, reverted because a bot sitting still with its bags
--- window never opened — no UI clicks to create fresh holes for pass 2 to
--- even see — could pick up new loot that silently never made it into the
--- cache once the tail had already reached bagTotal).
---@param cache table          AltBot_SavedVars.bagsCache[key] — mutated in place.
---@param freshItems table     Array of {link, count} from a fresh "items" reply.
---@param soldLinks table      Set of links sold/traded away THIS session (never resurrected).
---@param bagTotal number|nil  The bot's real total bag slot count (from "stats"); unused now that holes always take priority over the tail, kept for call-site compatibility.
---@return number              The new max occupied index in cache, for f.itemsMaxIndex.
local function MergeBagsUpdate(cache, freshItems, soldLinks, bagTotal)
    -- link -> QUEUE of fresh items sharing that link, not a single item —
    -- two separate stacks of the same reagent (same hyperlink, didn't fully
    -- merge into one stack server-side) would otherwise collapse onto one
    -- fresh object, falsely holing out whichever cached slot lost the race
    -- and re-appending it at the tail, silently destroying the user's own
    -- drag&drop ordering for duplicate-link stacks. Pass 1 below pops one
    -- entry per matching cached slot (FIFO), keeping each cached slot's
    -- position stable even when several slots share the same link.
    local freshByLink = {}
    for _, item in ipairs(freshItems) do
        local link = item.link
        freshByLink[link] = freshByLink[link] or {}
        local q = freshByLink[link]
        q[#q + 1] = item
    end

    local maxIndex = 0
    for i in pairs(cache) do
        if i > maxIndex then maxIndex = i end
    end
    -- Pass 1: update/hole-out existing slots, tracking which fresh links
    -- were already accounted for (so pass 2 only appends genuinely NEW
    -- items, not duplicates of ones already sitting in their own slot).
    for i, cached in pairs(cache) do
        local q = cached and freshByLink[cached.link]
        local fresh = q and table.remove(q, 1)
        if fresh then
            cache[i] = fresh
        elseif cached and not soldLinks[cached.link] then
            -- Vanished from the server's own list, and not something we
            -- removed locally this session — something else took it
            -- (another window, a manual whisper, etc). Hole it out.
            cache[i] = nil
        end
        -- else: cached[i] already nil (an existing hole), or it's a link we
        -- sold this session and the server just hasn't caught up — leave it.
    end

    -- Collect EVERY hole in 1..maxIndex for pass 2's tail-overflow fallback —
    -- not just the ones pass 1 just created. pairs(cache) never visits an
    -- index whose value is already nil, so a hole left by a PREVIOUS merge
    -- call (or by RemoveBagsItemOptimistically) was invisible to the old
    -- "only just-holed indexes" list; once the tail reached bagTotal, pass 2
    -- had nowhere it could see to put a genuinely new item and silently
    -- dropped it — confirmed in-game: a bot sitting in Farm mode (no UI
    -- clicks to create fresh holes) that picked up new loot while its cache
    -- was already at bagTotal just never showed those new items, server
    -- "stats" bagFree and this window's item count permanently diverging.
    local holeIndexes = {}
    for i = 1, maxIndex do
        if cache[i] == nil then
            holeIndexes[#holeIndexes + 1] = i
        end
    end

    -- Pass 2: place whatever's left in freshByLink (genuinely new items,
    -- including any leftover queue entries past what pass 1 claimed) into
    -- the FIRST available hole (ascending index) first, and only once every
    -- hole is filled does it append to the tail. Per explicit user
    -- direction: "удаляем те, что не стало, оставляя дырки, добавляем новые
    -- не в конец, а с первой дырки" — holes take priority over the tail,
    -- the opposite of this function's earlier tail-first behavior.
    local holeCursor = 1
    for _, item in ipairs(freshItems) do
        local q = freshByLink[item.link]
        -- Only place items still sitting in their link's queue — pass 1
        -- already popped off however many of each link it matched to
        -- existing cached slots, so this skips those, placing only the
        -- genuinely-unclaimed remainder, in the server's own original order.
        if q and q[1] == item then
            table.remove(q, 1)
            -- A leftover of a link sold/traded away while the window was open is the
            -- server's not-yet-updated list bringing it back - never re-add it
            -- (the optimistic removal left a hole, which pass 2 used to refill).
            if soldLinks[item.link] then
                -- skip
            elseif holeCursor <= #holeIndexes then
                cache[holeIndexes[holeCursor]] = item
                holeCursor = holeCursor + 1
            else
                maxIndex = maxIndex + 1
                cache[maxIndex] = item
            end
        end
    end

    return maxIndex
end

local bagsItemsTicker = CreateFrame("Frame")
bagsItemsTicker:SetScript("OnUpdate", function(self, dt)
    for key, collecting in pairs(bagsItemsAwaiting) do
        collecting.timer = collecting.timer + dt
        if collecting.timer >= NS.STATS_TIMEOUT then
            bagsItemsAwaiting[key] = nil
            NS.CheckBotSupplies(key, collecting.items)
            -- A poll-cycle fetch NEVER touches the cache (or repaints) while this bot's
            -- bags window is open: the user is working in it - selling, trading - and the
            -- reply, which doesn't know about those actions yet, brought sold items back
            -- (per explicit user direction). The window's own open/close fetches do the
            -- syncing.
            local openWindow = NS.botBagsFrames[key]
            if not (collecting.fromPoll and openWindow and openWindow:IsShown()) then
            local cache = AltBot_SavedVars.bagsCache[key]

            local maxIndex
            if not cache then
                -- This bot's very first-ever fetch — nothing to diff
                -- against yet, so the fresh list IS the cache, in whatever
                -- order the server sent it.
                cache = collecting.items
                AltBot_SavedVars.bagsCache[key] = cache
                maxIndex = #collecting.items
            else
                -- Diff-merge even on close (isClosing used to mean "replace
                -- the cache outright here" — that silently threw away the
                -- user's own drag&drop ordering every time the window
                -- closed, since the fresh "items" reply is just the
                -- server's own order with no memory of any local
                -- rearrangement). soldLinks still applies on close too: any
                -- Sell/Trade/Destroy done just before closing shouldn't
                -- resurrect from a reply that hasn't caught up yet. Per
                -- explicit user direction: "устроенный мной ордер должен
                -- пережить релоад" — the close-triggered refetch is exactly
                -- the point where that ordering has to survive into the
                -- persisted cache.
                local rosterEntry = NS.bots[key]
                maxIndex = MergeBagsUpdate(cache, collecting.items, NS.bagsSessionSoldLinks[key] or {},
                    rosterEntry and rosterEntry.bagTotal)
            end

            local f = NS.botBagsFrames[key]
            if f then
                f.items = cache
                -- Tracks how far items[] actually extends, separately from
                -- #f.items — once holes exist (from MergeBagsUpdate or
                -- RemoveBagsItemOptimistically), Lua's # operator on a table
                -- with holes is undefined, so anything walking every slot
                -- has to use this instead of ipairs/# on f.items directly.
                f.itemsMaxIndex = maxIndex
                local rosterEntry = NS.bots[key]
                PaintBagsFrame(f.botName, cache,
                    rosterEntry and rosterEntry.bagTotal,
                    rosterEntry and rosterEntry.bagFree,
                    rosterEntry and rosterEntry.money)
            end
            end   -- (not a poll fetch of an open window)
        end
    end
end)

--- Re-sends "items" for a bot, merging the reply into the persistent cache
--- (AltBot_SavedVars.bagsCache) rather than replacing it outright — see this
--- section's own header comment for the full diff/session-sold-filtering
--- behavior. Used both for the window-open fetch and the window-close
--- re-sync (NS.ToggleBotBags/the × button) — both paths merge the same way,
--- so the user's own drag&drop ordering survives either one.
NS.RefreshBotBagsItems = function(botName, fromPoll)
    local key = strlower(botName)
    -- A fetch for this bot is already collecting (the poll cycle's, or one the
    -- bags window started): don't start a second one on top of it — replacing
    -- the collector threw away the lines already received (truncated lists,
    -- false "no ammo/poison" alarms) and a second "items" reply would only
    -- duplicate every line. The running fetch repaints an open window itself.
    if bagsItemsAwaiting[key] then
        bagsItemsAwaiting[key].timer = 0
        -- The window asks while a poll fetch is already underway: adopt it as the
        -- window's own (its reply is wanted by the window, not discarded).
        if not fromPoll then bagsItemsAwaiting[key].fromPoll = nil end
        return
    end
    bagsItemsAwaiting[key] = { items = {}, timer = 0, fromPoll = fromPoll or nil }
    SendBotCommand(botName, "items")
end

--- Poll-cycle entry point: refreshes this bot's "items" cache in the
--- background (so it's current even if the bags window hasn't been opened
--- lately) and runs the ammo/poison check on the result. Skipped while a
--- fetch for the bot is already collecting (e.g. its bags window just
--- opened/closed) — never doubles up.
NS.PollBotItems = function(botName)
    local key = strlower(botName)
    local openWindow = NS.botBagsFrames[key]
    if openWindow and openWindow:IsShown() then return end   -- the poll stays away from an open bags window
    if bagsItemsAwaiting[key] then return end
    NS.RefreshBotBagsItems(botName, true)
end

--- Opens (painting the persistent cache instantly, then fetching fresh
--- items in the background) or closes (fetching one final AUTHORITATIVE
--- items reply) `botName`'s bags window. Slot count/money come from the
--- roster's own background "stats" poll (NS.bots[key]) — no separate
--- request for them any more.
NS.ToggleBotBags = function(botName)
    local key = strlower(botName)
    local f = GetOrCreateBagsFrame(botName)
    if f:IsShown() then
        f:Hide()
        -- Re-syncs with the server on close — see the × button's own
        -- comment above for why this isn't done after each action instead.
        -- Diff-merges into the persistent cache same as any other refresh
        -- (see NS.RefreshBotBagsItems/MergeBagsUpdate's own doc comments),
        -- so the user's own drag&drop ordering survives.
        NS.RefreshBotBagsItems(botName)
        NS.bagsSessionSoldLinks[key] = nil
        return
    end

    -- Fresh session-sold tracking for this open — per explicit user
    -- direction, this only ever needs to cover items sold/traded away WHILE
    -- this particular open is active.
    NS.bagsSessionSoldLinks[key] = {}

    -- GetOrCreateBagsFrame builds all ITEM_MAX_SLOTS (136) cells and sizes
    -- the frame for that full grid before this function ever paints
    -- anything — a first-ever open used to :Show() that raw 136-slot frame
    -- as-is and only fix its size once the "items" reply landed several
    -- seconds later, which looked exactly like a broken 8x17 grid (confirmed
    -- by the user in-game). Paint the real bagTotal-sized layout FIRST, from
    -- the persistent cache (instant — survives /reload, see this section's
    -- own header comment), then show. The roster's own background "stats"
    -- poll (NS.bots[key]) already knows bagTotal by the time this can even
    -- be clicked — the board's own bags column, which this click came from,
    -- reads the exact same field.
    -- First-ever open for this bot (no cache saved yet): show an explicitly
    -- EMPTY bag — not stale/placeholder data of any kind — and wait for the
    -- background "items" fetch kicked off below to populate it for the
    -- first time, per explicit user direction ("нужно показать пустую сумку
    -- и ждать апдейта который запущен с открытием окна"). Once that first
    -- reply lands, the ticker's own "not cache" branch (see MergeBagsUpdate's
    -- call site) treats it as authoritative and saves it as this bot's cache
    -- outright, same as closing does — there's nothing to diff against yet.
    local cache = AltBot_SavedVars.bagsCache[key] or {}
    f.items = cache
    f.itemsMaxIndex = 0
    for i in pairs(cache) do
        if i > f.itemsMaxIndex then f.itemsMaxIndex = i end
    end
    local rosterEntry = NS.bots[key]
    PaintBagsFrame(botName, cache,
        rosterEntry and rosterEntry.bagTotal,
        rosterEntry and rosterEntry.bagFree,
        rosterEntry and rosterEntry.money)
    f:Show()

    -- Kicks off the background "items" fetch this open is waiting on — for
    -- a bot with no cache yet, this IS the update that will first populate
    -- the empty bag just painted above.
    NS.RefreshBotBagsItems(botName)
end

-- NS.GetOpenDetailFrame is now ORPHANED: the old shared model+equip+
-- strategy+quests window has been dismantled (armory is its own per-bot
-- window below, NS.botArmoryFrames/GetOrCreateArmoryFrame/NS.ToggleBotArmory;
-- strategy/quest-log will each get their own standalone per-bot window in a
-- later pass). Kept defined (not deleted) purely because
-- NS.RenderStrategyPanel/the strategy+quest whisper-reply handlers further
-- below still call it — those are themselves orphaned for now (no UI calls
-- into them any more) and will be rewired onto the future standalone
-- strategy/quest-log windows instead of this helper. NS.botDetailFrame no
-- longer exists, so this currently always returns nil.
---@param key string  Lowercased bot name-key to check against.
---@return table|nil   The shared frame, only if it's open and bound to `key`.
NS.GetOpenDetailFrame = function(key)
    local f = NS.botDetailFrame
    if f and f:IsShown() and strlower(f.botName or "") == key then
        return f
    end
    return nil
end

-- ============================================================
-- Combat / Non-Combat strategy toggles — shown in the same window as the
-- inventory, switched with 2 buttons ("инвентарь всегда виден, кнопки
-- переключают combat/non-combat рядом" / "все подсмотри у cleanbot" /
-- "только убрать лишнее"). Data trimmed from CleanBot's
-- Individual/Strategies.lua: simple checkbox groups only. Deliberately NOT
-- ported yet (left for a later pass, per "весь функционал cleanbot со
-- временем"): the exclusive roleDropdown+subGroups (Role/Tank/Healer/DPS
-- rotation tree), classOnly/cmdByClass per-class overrides, timerSlider,
-- and settingDropdown (loot quality) — those need the class-strategy data
-- (ClassData.lua, 678 lines) and a fair bit more rendering logic than a
-- flat checkbox list.
-- ============================================================
-- Movement strategies shared by BOTH the combat "Combat Movement" dropdown
-- and the non-combat "Movement" dropdown — same 5 mutually-exclusive tokens
-- in both engines (mirrors CleanBot's NS.MOVEMENT_STRATEGIES).
NS.MOVEMENT_STRATEGIES = {
    { cmd = "follow",         field = "mFollow",   name = "Follow" },
    { cmd = "stay",           field = "mStay",     name = "Stay" },
    { cmd = "guard",          field = "mGuard",    name = "Guard" },
    { cmd = "runaway",        field = "mRunaway",  name = "Run Away" },
    { cmd = "flee from adds", field = "mFleeAdds", name = "Flee from Adds" },
}

NS.COMBAT_STRATEGIES = {
    -- Role: exclusive Tank/Healer/(Paladin-only Off-Heal) dropdown, "DPS" is
    -- the noneLabel (no rotation token = the talent spec's own rotation).
    -- cmdByClass covers classes whose engine registers the role under a
    -- different token (druid tanks as "bear", heals as "resto"; etc — see
    -- CleanBot's STRATEGY_CLASS_SUPPORT commentary for the source-verified
    -- per-class tokens).
    { header = "Combat Role", group = "role", column = "left", subAfter = "assist", type = "roleDropdown", noneLabel = "DPS",
      dpsCmdByClass = { PALADIN = "dps", PRIEST = "dps" },
      strategies = {
          { cmd = "tank", field = "isTank",   name = "Tank",
            cmdByClass = { DRUID = "bear", DEATHKNIGHT = "blood" } },
          { cmd = "heal", field = "isHealer", name = "Healer",
            cmdByClass = { DRUID = "resto", SHAMAN = "resto" } },
          { cmd = "offheal", field = "offheal", name = "Off-Heal", classOnly = "PALADIN" },
      },
      -- Sub-sections shown under Role depending on which token is active.
      subGroups = {
          { none = true, roles = { "offheal" }, header = "DPS", strategies = {
              { type = "dropdown", group = "dpsRotation", header = "Rotation", noneLabel = "Balanced",
                strategies = {
                    { cmd = "focus", field = "focusFire", name = "Focus Fire" },
                    { cmd = "aoe",   field = "aoeTarget",  name = "AoE Rotation" },
                } },
              { cmd = "threat",  field = "avoidAggro", name = "Avoid Aggro" },
              { cmd = "offheal", field = "offheal",    name = "Off-Heal", classOnly = "DRUID" },
          }},
          { field = "isTank", header = "Tank", strategies = {
              { cmd = "pull",      field = "pull",           name = "Pull" },
              { cmd = "pull back", field = "pullBack",       name = "Pull Back" },
              { cmd = "tank face", field = "faceTargetAway", name = "Face Target Away" },
              { cmd = "offheal",   field = "offheal",        name = "Off-Heal", classOnly = "DRUID" },
          }},
          { field = "isHealer", header = "Healing", strategies = {
              { cmd = "save mana",  field = "saveMana",  name = "Save Mana" },
              { cmd = "healer dps", field = "healerDps", name = "Healer DPS" },
          }},
      } },
    -- Targeting: orthogonal to Role — who to focus, independent of tank/heal/dps.
    { header = "Targeting", group = "assist", column = "left", type = "dropdown", noneLabel = "None", strategies = {
        { cmd = "dps assist",  field = "assistSingle", name = "Focus Down" },
        { cmd = "dps aoe",     field = "assistAoe",    name = "Cleave Anchor" },
        { cmd = "tank assist", field = "assistTank",   name = "Peel" },
    }},
    { header = "Combat Control", column = "left", strategies = {
        { cmd = "potions",    field = "usePotions",   name = "Use Potions",   default = true },
        { cmd = "boost",      field = "useCooldowns", name = "Use Cooldowns", default = true },
        { cmd = "racials",    field = "useRacials",   name = "Use Racials",   default = true },
        { cmd = "cc",         field = "useCC",        name = "Crowd Control" },
        { cmd = "aggressive", field = "aggressive",   name = "Aggressive" },
    }},
    -- Combat Movement: pin a position during combat (default empty — combat
    -- positioning like Kite/Distance decides where to stand otherwise).
    { header = "Combat Movement", column = "right", type = "dropdown", noneLabel = "Free Roam",
      strategies = NS.MOVEMENT_STRATEGIES },
    { header = "Positioning", column = "right", strategies = {
        -- Distance: inline exclusive dropdown leading the Positioning group.
        { type = "dropdown", group = "posMode", header = "Distance", noneLabel = "Default",
          strategies = {
              { cmd = "close",  field = "posClose",  name = "Close (Melee)" },
              { cmd = "ranged", field = "posRanged", name = "Ranged (Caster)" },
          } },
        { cmd = "kite",      field = "kite",             name = "Kite" },
        { cmd = "avoid aoe", field = "avoidAoe",         name = "Avoid AoE" },
        { cmd = "behind",    field = "stayBehindTarget", name = "Stay Behind Target" },
    }},
    { header = "Timing Controls", column = "right", strategies = {
        { cmd = "cast time", field = "castTime", name = "Smart Cast Time", default = true },
        { cmd = "wait for attack", field = "waitAttack", name = "Enable Wait to Attack" },
        { cmd = "wait for attack time", field = "waitAttackTime", name = "Delay",
          type = "timerSlider", min = 1, max = 10, dependsOn = "waitAttack" },
    }},
    { header = "Other", column = "right", strategies = {
        { cmd = "mark rti", field = "markTargets", name = "Mark Targets" },
        { cmd = "grind",    field = "grindMobs",   name = "Grind Mobs" },
    }},
}

NS.NC_STRATEGIES = {
    { header = "Non-Combat General", column = "right", strategies = {
        { cmd = "food", field = "useFood",   name = "Eat & Drink", default = true },
        { cmd = "pvp",  field = "enablePVP", name = "Enable PvP",  default = true },
    }},
    -- Out-of-combat movement — a fresh bot defaults to Follow here.
    { header = "Non-Combat Movement", column = "right", type = "dropdown", noneLabel = "Free Roam",
      defaultField = "mFollow", strategies = NS.MOVEMENT_STRATEGIES },
    { header = "Loot & Gather", column = "left", strategies = {
        { cmd = "loot",   field = "autoLoot",   name = "Auto Loot",   default = true },
        { cmd = "gather", field = "autoGather", name = "Auto Gather", default = true },
    }},
    -- Loot-quality policy: the "ll" command SETTING (queried with "ll ?"), not an nc
    -- on/off strategy - its own dropdown type, reply "Loot strategy: <mode>".
    { header = "Loot Quality", column = "left", type = "settingDropdown",
      cmd = "ll", field = "lootStrategy", options = {
        { value = "all",        name = "All" },
        { value = "normal",     name = "Normal" },
        { value = "disenchant", name = "Disenchant" },
        { value = "gray",       name = "Gray" },
    }},
}

--- Iterates the leaf strategies of a list, descending one level into inline
--- exclusive-dropdown bundles (type="dropdown", whose own `strategies` are
--- the real toggles) — mirrors CleanBot's CB_EachLeafStrategy. Lets callers
--- (token mapping, height calc) treat a bundle's options as ordinary
--- strategies without special-casing dropdowns everywhere.
local function EachLeafStrategy(list, fn)
    for _, s in ipairs(list) do
        if s.type == "dropdown" then
            for _, n in ipairs(s.strategies) do fn(n) end
        else
            fn(s)
        end
    end
end

--- Builds cmd(+cmdByClass alt tokens)->field lookup tables (for parsing
--- co?/nc? replies) from the strategy group lists above — descends into
--- inline dropdown bundles AND roleDropdown subGroups via EachLeafStrategy,
--- and skips timerSlider entries (their cmd takes a value, e.g. "wait for
--- attack time 5" — it's never a bare token a co?/nc? reply echoes back, so
--- mapping it would seed a numeric field false on every reply parse).
local function BuildStrategyMap(groups)
    local map = {}
    local function mapOne(s)
        if s.type == "timerSlider" then return end
        map[s.cmd] = s.field
        if s.cmdByClass then
            for _, alt in pairs(s.cmdByClass) do map[alt] = s.field end
        end
    end
    for _, grp in ipairs(groups) do
        if grp.strategies then EachLeafStrategy(grp.strategies, mapOne) end
        if grp.subGroups then
            for _, sg in ipairs(grp.subGroups) do
                EachLeafStrategy(sg.strategies, mapOne)
            end
        end
    end
    return map
end
NS.STRATEGY_MAP    = BuildStrategyMap(NS.COMBAT_STRATEGIES)
NS.NC_STRATEGY_MAP = BuildStrategyMap(NS.NC_STRATEGIES)

--- Parses a "co ?"/"nc ?" reply ("Strategies: tokenA,tokenB,...") into a
--- { field = bool } table, seeding every known field false first.
local function ParseStrategyReply(msg, map)
    local result = {}
    for _, field in pairs(map) do result[field] = false end
    if not msg or msg == "" then return result end
    local colon = strfind(msg, ":", 1, true)
    local list  = colon and strsub(msg, colon + 1) or msg
    for token in msg:gmatch("[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        local field = map[token]
        if field then result[field] = true end
    end
    return result
end

-- ============================================================
-- Builds (once) and returns the inventory+strategy window for a given bot
-- name. Inventory grid is always visible (left side); Combat/Non-Combat
-- checkbox panel is on the right, switched by 2 buttons above it.
-- ============================================================
--- Finds the live group unit token for a tracked bot name, or nil if not
--- currently grouped. The detail window only shows gear for grouped bots —
--- GetInventoryItemTexture/Link need a live unit, and this window is only
--- ever opened for tracked roster bots, which GroupRoster keeps grouped.
local function FindBotUnit(botName)
    local key = strlower(botName)
    local found
    ForEachGroupMember(function(unit, name)
        if name and strlower(name) == key then found = unit end
    end)
    return found
end

--- Tooltip for one armory slot: the cached item link first (works at any
--- distance), else the live group unit's own slot, else just the slot name.
local function ShowEquipTooltip(f, btn)
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    local links = NS.botEquipLinks[strlower(f.botName or "")]
    local link = links and links[btn.slotId]
    if link then
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
        return
    end
    local unit = f.unit
    if unit and UnitExists(unit) and GameTooltip:SetInventoryItem(unit, btn.slotId) then
        GameTooltip:Show()
        return
    end
    GameTooltip:AddLine(btn.slotName, 1, 1, 1)
    GameTooltip:Show()
end

--- Builds one equip-slot button (paperdoll icon) for the detail window,
--- positioned per `eqdef` (see EQUIP_SLOTS) around the model. View-only:
--- no drag/unequip/right-click menu, just icon + tooltip.
local function CreateEquipSlot(f, eqdef, g)
    local btn = CreateFrame("Button", nil, f.model)
    btn:SetSize(g.slot, g.slot)

    local yOff = -(g.headerH + (eqdef.order - 1) * g.step)
    if eqdef.side == "left" then
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", g.leftX, yOff)
    elseif eqdef.side == "right" then
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", g.rightX, yOff)
    else -- "bottom" — weapon row; positioned by the caller
        return btn
    end

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn)
    bg:SetTexture(eqdef.tex)
    btn.bg = bg

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(btn)
    icon:Hide()
    btn.icon = icon

    btn.slotId   = eqdef.id
    btn.slotName = eqdef.name

    btn:SetScript("OnEnter", function(self) ShowEquipTooltip(f, self) end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return btn
end

-- Per-bot equipment cache (NOT just "whatever the shared window last
-- painted") — { [nameKey] = { [slotId] = textureOrFalse, ... } } — so
-- switching to a PREVIOUSLY-viewed bot shows its last-known gear instantly,
-- before a fresh slot-query pass has had a chance to confirm it, per
-- explicit user direction ("держать последний эквип для всех ботов в
-- кэше, сразу его показывать"). Filled exclusively by the whisper-based
-- slot query below (RequestEquipSlot/NS.RefreshBotEquipBackground) — no
-- client-side inspect API involved, so this works regardless of the bot's
-- distance from the player (per explicit user direction: "показ шмоток...
-- означает что бот должен быть рядом, это плохо").
-- textureOrFalse: `false` (not nil) records "this slot is empty" as a real
-- cached fact, distinct from "never read" (an absent key), so an empty
-- slot doesn't fall through and look unread on the next open.
NS.botEquipCache = NS.botEquipCache or {}
-- Item links of the same slots - { [nameKey] = { [slotId] = link } } - so a
-- slot can show the real item tooltip even when the bot isn't a live group
-- unit (persisted like the texture cache, see the ADDON_LOADED handler).
NS.botEquipLinks = NS.botEquipLinks or {}
NS.botWho = NS.botWho or {}   -- lower(name) -> parsed "who" reply (see NS.ParseWhoReply)

--- Paints f's equip slots from NS.botEquipCache[key] alone — no unit, no
--- whisper, just whatever was last recorded (nothing shown for a slot
--- that's never been read at all, i.e. absent from the cache). Used to
--- redisplay a bot's last-known gear instantly on open/switch, before a
--- fresh slot-query pass (NS.RefreshBotEquipBackground) has had a chance to
--- confirm it's still current.
--- Ammo slot of the armory. In WotLK the ammo slot only holds an ammo ITEM ID -
--- the arrows/bullets themselves stay in the bags - and there's no whisper
--- keyword for it, so: the live group unit's own ammo slot when the client
--- exposes it, otherwise (hunters) the best ammo found in the bot's cached
--- bag list (highest item level, then biggest stack), with its stack count.
NS.PaintArmoryAmmo = function(f, key)
    local ammo = f.equipSlots[0]
    if not ammo then return end
    local links = NS.botEquipLinks[key] or {}
    NS.botEquipLinks[key] = links

    local link, count
    if f.unit and UnitExists(f.unit) and GetInventoryItemTexture(f.unit, 0) then
        link = GetInventoryItemLink(f.unit, 0)
    end
    local entry = NS.bots[key]
    if not link and entry and entry.class == "HUNTER" then
        local bags = AltBot_SavedVars.bagsCache and AltBot_SavedVars.bagsCache[key]
        local bestIlvl = -1
        for _, item in pairs(bags or {}) do
            if type(item) == "table" and item.link and NS.IsAmmoItem(NS.SupplyItemInfo(item.link)) then
                local _, _, _, ilvl = GetItemInfo(item.link)
                ilvl = ilvl or 0
                if ilvl > bestIlvl or (ilvl == bestIlvl and (item.count or 0) > (count or 0)) then
                    bestIlvl, link, count = ilvl, item.link, item.count
                end
            end
        end
    end

    links[0] = link
    local itemId = link and link:match("item:(%d+)")
    local tex = itemId and GetItemIcon(tonumber(itemId))
    if tex then
        ammo.icon:SetTexture(tex)
        ammo.icon:Show()
        if ammo.bg then ammo.bg:Hide() end
        -- Over 999 the number wouldn't fit the small slot: shown as "*" (per explicit user direction).
        ammo.countText:SetText((count and count > 999) and "*" or ((count and count > 1) and count or ""))
    else
        ammo.icon:Hide()
        if ammo.bg then ammo.bg:Show() end
        ammo.countText:SetText("")
    end
end

local function PaintEquipSlotsFromCache(f, key)
    NS.PaintArmoryAmmo(f, key)
    local cache = NS.botEquipCache[key]
    if not cache then return end
    for slotId, btn in pairs(f.equipSlots) do
        local tex = cache[slotId]
        if tex then
            btn.icon:SetTexture(tex)
            btn.icon:Show()
            if btn.bg then btn.bg:Hide() end
        elseif tex == false then
            btn.icon:Hide()
            if btn.bg then btn.bg:Show() end
        end
        -- tex == nil (slot never read for this bot): leave whatever's
        -- currently displayed rather than asserting an empty slot we don't
        -- actually know is empty.
    end
end

-- GetInventoryItemTexture/NotifyInspect only work while the bot is a
-- nearby, inspectable group unit — useless once a bot wanders off
-- questing/farming out of range, which is exactly when its gear most needs
-- to stay current in the DB. mod-playerbots' documented "Item Keywords"
-- (https://github.com/mod-playerbots/mod-playerbots/wiki/Playerbot-Commands#items)
-- — "head", "neck", "shoulder", "shirt", "chest", "waist", "legs", "feet",
-- "wrist", "hands", "finger 1", "finger 2", "trinket 1", "trinket 2",
-- "back", "main hand", "off hand", "ranged", "tabard" — whispered VERBATIM
-- as the whole message double as a per-slot items query: the bot replies
-- "=== Inventory ===" plus the equipped item's link (or nothing, if the
-- slot is empty), same shape as the "items" (bags) reply. This works at
-- ANY distance since it's a plain whisper, not a client-side inspect.
--
-- Side effect confirmed in-game: mod-playerbots treats the whispered
-- keyword as "talking about an item" and has the bot open a TRADE window
-- with the player in response — happens on every slot query, empty or not.
-- NS.equipSlotQueryDepth (below) tracks "a slot query round-trip is in
-- flight" and the tradeSuppressor frame cancels any TRADE_SHOW that fires
-- while it's nonzero, so this never surfaces to the player.
-- slotId -> exact whisper keyword text (the wiki-documented spelling,
-- independent of EQUIP_SLOTS' own `name` field so a future label change
-- there can't silently break the whisper text).
local EQUIP_SLOT_KEYWORD = {
    [1]  = "head",       [2]  = "neck",       [3]  = "shoulder",
    [15] = "back",       [5]  = "chest",      [4]  = "shirt",
    [19] = "tabard",     [9]  = "wrist",      [10] = "hands",
    [6]  = "waist",      [7]  = "legs",       [8]  = "feet",
    [11] = "finger 1",   [12] = "finger 2",   [13] = "trinket 1",
    [14] = "trinket 2",  [16] = "main hand",  [17] = "off hand",
    [18] = "ranged",
}

local EQUIP_SLOT_TIMEOUT = 2.0   -- a slot reply is 1-2 short lines; no need for the full STATS_TIMEOUT

-- Suppresses the bot-initiated TRADE_SHOW popup that mod-playerbots fires
-- in response to every slot-keyword whisper (see comment above). Counter,
-- not a boolean — multiple slot queries can overlap in flight.
--
-- CancelTrade() alone isn't enough — it tells the server/client to end the
-- trade session, but Blizzard's own TRADE_SHOW handler has already called
-- TradeFrame:Show() by the time our handler runs (same event, and frame
-- load order isn't guaranteed to put this one first), so the window still
-- flashes open for a frame before CancelTrade's result closes it. Hiding
-- TradeFrame directly, in the same breath, is what actually makes it never
-- visibly appear.
--
-- The open/close SOUNDKIT cue itself is fired by Blizzard's own
-- TradeFrame OnShow/OnHide handlers (FrameXML), not anything reachable
-- through our own PlaySound calls — there's no per-sound handle to stop.
-- The only lever is a blunt one: briefly flip Sound_EnableSFX off around
-- this event and restore it a frame later, muting ALL sound effects (not
-- just this one) for that instant. Accepted trade-off, per explicit user
-- confirmation, to kill the trade whoosh that plays on every one of the
-- 19 per-slot equip queries.
local prevSFXCVar = nil
local TRADE_CANCEL_QUIET = 3.0   -- seconds after a slot query during which "Сделка отменена." is hidden (see below)
NS.equipSlotQueryDepth = 0
local tradeSuppressor = CreateFrame("Frame")
tradeSuppressor:RegisterEvent("TRADE_SHOW")
tradeSuppressor:SetScript("OnEvent", function()
    -- Only the trade a queried bot opened in answer to its slot query - never
    -- one the user started (a vendor/trade of their own during a background pass).
    local partner = TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText()
    if NS.equipSlotQueryDepth > 0 and (not partner or partner == ""
        or (NS.equipAwaiting and NS.equipAwaiting[strlower(partner)])) then
        NS.tradeCancelQuietUntil = GetTime() + TRADE_CANCEL_QUIET
        prevSFXCVar = GetCVar("Sound_EnableSFX")
        SetCVar("Sound_EnableSFX", "0")
        CancelTrade()
        -- HideUIPanel, NOT TradeFrame:Hide(): a bare Hide() leaves the client
        -- believing the trade window still occupies its UI panel slot, and
        -- Escape then keeps "closing" that ghost instead of opening the game
        -- menu until the next /reload.
        if TradeFrame and TradeFrame:IsShown() then
            HideUIPanel(TradeFrame)
        end
        NS.After(0, function()
            if prevSFXCVar then
                SetCVar("Sound_EnableSFX", prevSFXCVar)
                prevSFXCVar = nil
            end
        end)
    end
end)

-- The trade window's open/close cue is a plain global PlaySound() call from Blizzard's own
-- TradeFrame OnShow/OnHide (looked up at call time), so it CAN be intercepted: drop those
-- two cues while a slot query is in flight (or just after it), per explicit user direction
-- (the whoosh still broke through although the window itself was suppressed). The brief
-- Sound_EnableSFX mute above stays as a fallback - it runs too late for the OnShow cue.
if PlaySound then
    local origPlaySound = PlaySound
    PlaySound = function(sound, ...)
        if (sound == "igCharacterInfoOpen" or sound == "igCharacterInfoClose")
            and ((NS.equipSlotQueryDepth or 0) > 0 or GetTime() < (NS.tradeCancelQuietUntil or 0)) then
            return
        end
        return origPlaySound(sound, ...)
    end
end

-- The "Сделка отменена." (ERR_TRADE_CANCELLED) line that pops up on screen
-- every time tradeSuppressor above cancels a slot query's bot-initiated trade
-- is hidden - but only within a few seconds of such a query, so a trade the
-- user cancels themselves still reports normally. UIErrorsFrame is where the
-- client prints it (yellow text in the middle of the screen).
NS.tradeCancelQuietUntil = 0
if UIErrorsFrame then
    local origAddMessage = UIErrorsFrame.AddMessage
    UIErrorsFrame.AddMessage = function(self, msg, ...)
        if msg == ERR_TRADE_CANCELLED and GetTime() < NS.tradeCancelQuietUntil then return end
        return origAddMessage(self, msg, ...)
    end
end

local equipSlotAwaiting = {}   -- lower(name) -> { slotId = eqSlotId, timer = number }
NS.equipAwaiting = equipSlotAwaiting   -- read by the trade suppressor above

-- The slot keyword ("head", "ranged", ...) is ALSO matched against bag items
-- by name, so the reply can list e.g. a "Mithril Head Trout" from the bags
-- next to (or instead of) the equipped helm. Only an item whose equip type
-- really fits the queried slot counts as that slot's gear.
NS.SLOT_EQUIP_LOC = {
    [1]  = { INVTYPE_HEAD = true },     [2]  = { INVTYPE_NECK = true },
    [3]  = { INVTYPE_SHOULDER = true }, [4]  = { INVTYPE_BODY = true },
    [5]  = { INVTYPE_CHEST = true, INVTYPE_ROBE = true },
    [6]  = { INVTYPE_WAIST = true },    [7]  = { INVTYPE_LEGS = true },
    [8]  = { INVTYPE_FEET = true },     [9]  = { INVTYPE_WRIST = true },
    [10] = { INVTYPE_HAND = true },
    [11] = { INVTYPE_FINGER = true },   [12] = { INVTYPE_FINGER = true },
    [13] = { INVTYPE_TRINKET = true },  [14] = { INVTYPE_TRINKET = true },
    [15] = { INVTYPE_CLOAK = true },    [19] = { INVTYPE_TABARD = true },
    [16] = { INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true },
    [17] = { INVTYPE_WEAPON = true, INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true },
    [18] = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true, INVTYPE_RELIC = true },
}

--- true = fits the slot, false = clearly doesn't, nil = the client doesn't
--- know the item yet (not cached).
NS.SlotAcceptsItem = function(slotId, link)
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
    if equipLoc == nil then return nil end
    local ok = NS.SLOT_EQUIP_LOC[slotId]
    return ok ~= nil and ok[equipLoc] == true
end

--- Whispers one slot's keyword to `botName` and resolves `cache[slotId]`
--- (texture or false) once the reply lands or the short timeout passes.
--- Only one slot in flight per bot at a time (queued by the caller loop).
local function RequestEquipSlot(botName, slotId, onDone)
    local key = strlower(botName)
    NS.equipSlotQueryDepth = NS.equipSlotQueryDepth + 1
    equipSlotAwaiting[key] = { slotId = slotId, link = nil, timer = 0, onDone = onDone }
    SendBotCommand(botName, EQUIP_SLOT_KEYWORD[slotId])
end

local equipSlotWatcher = CreateFrame("Frame")
equipSlotWatcher:RegisterEvent("CHAT_MSG_WHISPER")
equipSlotWatcher:SetScript("OnEvent", function(self, event, msg, sender)
    local key = strlower(sender or "")
    local collecting = equipSlotAwaiting[key]
    if not collecting then return end
    if strfind(msg, "|Hitem:", 1, true) then
        local item = ParseItemLine(msg)
        if item then
            local fits = NS.SlotAcceptsItem(collecting.slotId, item.link)
            if fits == true then
                collecting.link = item.link
            elseif fits == nil and not collecting.link then
                collecting.maybeLink = collecting.maybeLink or item.link   -- uncached: only if nothing verified turns up
            end
        end
    end
    collecting.timer = 0
end)

--- Drops this bot's in-flight slot query immediately (the armory window was
--- closed): it no longer counts as "being queried", so the trade suppressor
--- stays out of the way of a trade the user opens with that bot right after,
--- and the pass's bookkeeping is closed out through its own callback.
NS.CancelEquipPass = function(botName)
    local key = strlower(botName or "")
    local collecting = equipSlotAwaiting[key]
    if not collecting then return end
    equipSlotAwaiting[key] = nil
    NS.equipSlotQueryDepth = math.max(0, NS.equipSlotQueryDepth - 1)
    collecting.onDone(collecting.slotId, nil, nil)
end

local equipSlotTicker = CreateFrame("Frame")
equipSlotTicker:SetScript("OnUpdate", function(self, dt)
    local finished
    for key, collecting in pairs(equipSlotAwaiting) do
        collecting.timer = collecting.timer + dt
        if collecting.timer >= EQUIP_SLOT_TIMEOUT then
            finished = finished or {}
            finished[#finished + 1] = key
        end
    end
    if not finished then return end
    -- Handled after the traversal: onDone starts the NEXT slot query, i.e.
    -- assigns equipSlotAwaiting[key] again, and adding a key while pairs() is
    -- still walking the table is what raised "invalid key to 'next'".
    for _, key in ipairs(finished) do
        local collecting = equipSlotAwaiting[key]
        if collecting then
            equipSlotAwaiting[key] = nil
            NS.equipSlotQueryDepth = math.max(0, NS.equipSlotQueryDepth - 1)
            collecting.link = collecting.link or collecting.maybeLink
            local tex = false
            if collecting.link then
                local itemId = collecting.link:match("item:(%d+)")
                tex = (itemId and GetItemIcon(tonumber(itemId))) or false
            end
            collecting.onDone(collecting.slotId, tex, collecting.link)
        end
    end
end)

--- Repaints f's equip icons from NS.botEquipCache[key] and (re)binds the
--- model's unit only if the gear actually changed — no network call here,
--- pure cache-to-display. Called once after a bot's slot-query pass
--- finishes (see NS.RefreshBotEquipBackground), not per-slot, so the model
--- doesn't re-bind 18 times in a row.
-- The armory's 3D model. With the bot in view (a live group unit) it's that unit's
-- own model, exactly as it looks. Without one - the Farm roster is usually spread
-- over the world - a model is BUILT from what's cached: the race/gender from the
-- bot's "who" reply picks the base character model, and every cached equipment
-- link is tried on it (hair, skin and face are the race's defaults, not the bot's).
NS.ARMORY_BUILT_MODEL = false   -- the white-silhouette fallback (see UpdateArmoryModel); off
NS.ARMORY_BUILT_MODEL_SCALE = 0.5   -- size of the cache-built model in its frame (tune if it is too big/small)
NS.RACE_MODEL_DIR = {
    ["Human"] = "Human", ["Dwarf"] = "Dwarf", ["Night Elf"] = "NightElf", ["Gnome"] = "Gnome",
    ["Draenei"] = "Draenei", ["Orc"] = "Orc", ["Undead"] = "Scourge", ["Tauren"] = "Tauren",
    ["Troll"] = "Troll", ["Blood Elf"] = "BloodElf",
}

--- the model file path (Character/NightElf/Female/NightElfFemale.m2) for ("Night Elf", "F"); nil if unknown.
NS.RaceModelPath = function(race, gender)
    local dir = race and NS.RACE_MODEL_DIR[race]
    if not dir then return nil end
    local sex = gender == "F" and "Female" or "Male"
    return "Character\\" .. dir .. "\\" .. sex .. "\\" .. dir .. sex .. ".m2"
end

--- Puts every cached equipment link on the (built) model. Items the client hasn't
--- cached yet silently don't show, so this is repeated shortly after a rebuild.
NS.DressArmoryModel = function(f)
    local links = NS.botEquipLinks[strlower(f.botName or "")]
    if not links then return end
    if f.model.Undress then f.model:Undress() end
    for slotId = 1, 19 do
        if slotId ~= 0 and links[slotId] then f.model:TryOn(links[slotId]) end
    end
end

--- The retained model of a bot out of view shows its gear as of the last time it was
--- seen. Keep it current from the cached equipment links: strip it (the skin, hair
--- and face stay) and try every cached item on. Only when the cached set changed;
--- repeated shortly after, as items the client hasn't cached yet don't show at once.
NS.DressRetainedModel = function(f)
    local key = strlower(f.botName or "")
    local links = NS.botEquipLinks[key]
    if not links then return end
    local sig = ""
    for slotId = 1, 19 do sig = sig .. "|" .. tostring(links[slotId]) end
    if f.modelDressSig == sig then return end
    f.modelDressSig = sig
    local function dress()
        if f.model.Undress then f.model:Undress() end
        for slotId = 1, 19 do
            if links[slotId] then f.model:TryOn(links[slotId]) end
        end
    end
    dress()
    for _, delay in ipairs({ 0.6, 2.0, 5.0 }) do
        NS.After(delay, function()
            if f:IsShown() and f.modelMode == "unit" and not f.modelUnit and f.modelDressSig == sig then dress() end
        end)
    end
end

--- Shows the right model for the window: the live unit if there is one, else the
--- one built from cache (see above). Cheap to call again - it only rebuilds when
--- the unit, the race/gender or the set of cached items changed.
NS.UpdateArmoryModel = function(f)
    local key = strlower(f.botName or "")
    local unit = FindBotUnit(f.botName)
    f.unit = unit
    -- A far-away group member still has a unit token (UnitExists is true), but
    -- its model can't be drawn - empty frame. Only a unit the client actually has in
    -- view (UnitIsVisible) counts as "live"; otherwise the cached model is built.
    if unit and UnitExists(unit) and UnitIsVisible(unit) then
        if f.modelMode ~= "unit" or f.modelUnit ~= unit then
            f.model:SetUnit(unit)
            f.modelMode, f.modelUnit, f.modelSig, f.modelDressSig = "unit", unit, nil, nil
            if f.ApplyRotation then f.ApplyRotation() end
        end
        return
    end

    f.modelUnit = nil
    -- Out of view now, but the frame still holds the model it loaded the last time this
    -- bot WAS in view (this session): keep showing that - the bot's real, textured look.
    if f.modelMode == "unit" then
        NS.DressRetainedModel(f)
        return
    end
    -- Nothing seen yet this session. A model built from the race file alone comes out
    -- as an untextured white silhouette in this client (it loads no skin), so it is off
    -- unless NS.ARMORY_BUILT_MODEL is switched on.
    if not NS.ARMORY_BUILT_MODEL then
        if f.modelMode then f.model:ClearModel() end
        f.modelMode, f.modelSig = nil, nil
        return
    end
    local who = NS.botWho[key]
    local path = who and NS.RaceModelPath(who.race, who.gender)
    if not path then
        if f.modelMode then f.model:ClearModel() end
        f.modelMode, f.modelSig = nil, nil
        return
    end
    local links = NS.botEquipLinks[key] or {}
    local sig = path
    for slotId = 1, 19 do sig = sig .. "|" .. tostring(links[slotId]) end
    if f.modelMode == "built" and f.modelSig == sig then return end

    f.model:SetModel(path)
    if f.model.SetCamera then f.model:SetCamera(0) end
    -- A model set by file (not by unit) gets none of the frame defaults: it came out
    -- blown-out white and far too big. Give it the standard dress-up lighting, put it
    -- at the origin and scale it down so the whole figure fits the frame.
    if f.model.SetLight then
        f.model:SetLight(1, 0, -0.707, -0.707, 0.7, 1.0, 1.0, 1.0, 1.0, 0.8, 1.0, 1.0, 0.8)
    end
    if f.model.SetPosition then f.model:SetPosition(0, 0, 0) end
    if f.model.SetModelScale then f.model:SetModelScale(NS.ARMORY_BUILT_MODEL_SCALE) end
    f.modelMode, f.modelSig = "built", sig
    NS.DressArmoryModel(f)
    if f.ApplyRotation then f.ApplyRotation() end
    -- uncached items arrive a moment later: dress again
    for _, delay in ipairs({ 0.6, 2.0, 5.0 }) do
        NS.After(delay, function()
            if f:IsShown() and f.modelMode == "built" and f.modelSig == sig then
                NS.DressArmoryModel(f)
            end
        end)
    end
end

local function RepaintEquipFromCache(f, key)
    if not f or not f:IsShown() or strlower(f.botName or "") ~= key then return end
    local unit = FindBotUnit(f.botName)
    f.unit = unit
    PaintEquipSlotsFromCache(f, key)
    if NS.PaintArmoryHeader then NS.PaintArmoryHeader(f) end   -- iLevel comes from the freshly cached links
    NS.UpdateArmoryModel(f)
end

--- Closing the armory window while a slot query is still in flight is FICTIVE, per explicit
--- user direction: the window just turns invisible (alpha 0, moved off screen, still
--- "shown") until that last query is answered with the trade it provokes suppressed as
--- usual, and only then really closes. A window with no query in flight closes normally.
NS.CloseArmory = function(f)
    local key = strlower(f.botName or "")
    if f.closing then return end
    if f:IsShown() and NS.equipAwaiting and NS.equipAwaiting[key] then
        f.closing = true
        f.closePoint = { f:GetPoint() }
        f:SetAlpha(0)
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", -30000, 0)
    else
        f:Hide()
    end
end

--- Undoes the invisible state (position + alpha) without closing.
NS.RestoreArmoryVisible = function(f)
    if not f.closing then return end
    f.closing = false
    f:SetAlpha(1)
    local pt = f.closePoint
    f:ClearAllPoints()
    if pt then f:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5]) else f:SetPoint("CENTER", UIParent, "CENTER", -200, 0) end
    f.closePoint = nil
end

--- The pending fictive close is done: back to the real position, then really close.
NS.FinishArmoryClose = function(f)
    if not f.closing then return end
    NS.RestoreArmoryVisible(f)
    f:Hide()
end

--- Re-resolves f.unit (for tooltips/model) and repaints equip slots from
--- cache for every currently-OPEN armory window — no network call, just
--- catching the display up with whatever's already cached. Called on
--- group-roster-change events (join/leave/convert), where a bot's unit
--- token itself may have changed even though nothing warrants a fresh query.
--- Iterates NS.botArmoryFrames now that each bot has its own window, rather
--- than checking one shared frame.
NS.RepaintOpenDetailFrame = function()
    for key, f in pairs(NS.botArmoryFrames) do
        if f:IsShown() then
            RepaintEquipFromCache(f, key)
        end
    end
end

--- Equipment refresh for one bot: queries all 19 paperdoll slots by whisper,
--- one at a time (each waits for its own reply before the next is sent), and
--- writes each result into NS.botEquipCache[key] as it lands. Works at any
--- distance — no NotifyInspect, no group-proximity requirement. Called every
--- time this bot's armory window is opened (see NS.ToggleBotArmory) and by
--- its own Refresh icon while the window stays open — there is no background
--- poller filling this cache any more, so this is the only thing that keeps
--- it current.
NS.RefreshBotEquipBackground = function(botName, onFinished)
    local key = strlower(botName)
    local cache = NS.botEquipCache[key]
    if not cache then
        cache = {}
        NS.botEquipCache[key] = cache
    end
    local links = NS.botEquipLinks[key]
    if not links then
        links = {}
        NS.botEquipLinks[key] = links
    end

    local slotIds = {}
    for slotId in pairs(EQUIP_SLOT_KEYWORD) do slotIds[#slotIds + 1] = slotId end
    table.sort(slotIds)

    -- Marked as a manual-refresh chain regardless of caller (window-open
    -- fetch or its own Refresh icon) — see NS.BeginDetailFetch's own doc
    -- comment. The guard exists purely for the "Refresh clicked while the
    -- window-open fetch is still in flight" race for the same bot.
    NS.BeginDetailFetch(botName)

    local function step(i)
        local slotId = slotIds[i]
        if not slotId then
            local f = NS.botArmoryFrames[key]
            if f then RepaintEquipFromCache(f, key) end
            NS.EndDetailFetch(botName)
            if onFinished then onFinished() end
            if f then NS.FinishArmoryClose(f) end
            return
        end
        -- A slot query makes the bot open a trade with you (which closes
        -- whatever window you have up - mail, vendor, bank...), so queries are
        -- sent ONLY while this bot's armory window is open: closing the window
        -- ends the pass at the next slot (per explicit user direction).
        local armory = NS.botArmoryFrames[key]
        if not armory or not armory:IsShown() or armory.closing then
            NS.EndDetailFetch(botName)
            if onFinished then onFinished() end
            -- fictive close: the last in-flight query has been answered, close for real
            if armory then NS.FinishArmoryClose(armory) end
            return
        end
        RequestEquipSlot(botName, slotId, function(id, tex, link)
            if tex ~= nil then   -- nil = the query was aborted (window closed), keep what we had
                cache[id] = tex
                links[id] = link   -- nil for an empty slot
            end
            step(i + 1)
        end)
    end
    -- "who" goes out FIRST: its one-line reply (race/gender, spec + talents,
    -- class, level, GearScore) fills the armory header - see NS.ParseWhoReply.
    SendBotCommand(botName, "who")
    step(1)
end

-- Russian race names, [male, female] - fallback when the live unit isn't available.
NS.RACE_RU = {
    ["Human"] = { "Человек", "Человек" },      ["Dwarf"] = { "Дворф", "Дворфийка" },
    ["Night Elf"] = { "Ночной эльф", "Ночная эльфийка" }, ["Gnome"] = { "Гном", "Гномка" },
    ["Draenei"] = { "Дреней", "Дренейка" },    ["Orc"] = { "Орк", "Орчиха" },
    ["Undead"] = { "Нежить", "Нежить" },       ["Tauren"] = { "Таурен", "Тауренка" },
    ["Troll"] = { "Тролль", "Тролльчиха" },    ["Blood Elf"] = { "Эльф крови", "Эльфийка крови" },
}

--- Lowercases the first letter of a (UTF-8) word - Lua's lower() leaves Cyrillic alone.
NS.Utf8LowerFirst = function(text)
    local b1, b2 = text:byte(1, 2)
    if b1 == 0xD0 and b2 and b2 >= 0x90 and b2 <= 0x9F then
        return string.char(0xD0, b2 + 0x20) .. text:sub(3)
    elseif b1 == 0xD0 and b2 and b2 >= 0xA0 and b2 <= 0xAF then
        return string.char(0xD1, b2 - 0x20) .. text:sub(3)
    end
    return strlower(text:sub(1, 1)) .. text:sub(2)
end

--- Parses a bot's "who" reply, e.g. (color codes already stripped)
---   "Night Elf [F] beast mastery (18/0/0) hunter (28 lvl), 17 GS (11), (), playing with Xora"
--- into { race, gender, spec, talents, class, level, gs, ilvl }; nil if the
--- text isn't that shape.
NS.ParseWhoReply = function(raw)
    local text = NS.CleanEscapes(raw)
    local race, gender, rest = text:match("^%s*(.-) %[([MF])%] (.+)$")
    if not race then return nil end
    local spec, t1, t2, t3, rest2 = rest:match("^(.-) %((%d+)/(%d+)/(%d+)%) (.+)$")
    if not spec then return nil end
    local class, level, tail = rest2:match("^(.-) %((%d+) lvl%)(.*)$")
    if not class then return nil end
    -- GS and item level, tolerant of spacing: "17 GS (11)" / "17GS(11)" / "GS 17"
    local gs = tail:match("(%d+)%s*GS") or tail:match("GS:?%s*(%d+)")
    local ilvl = tail:match("GS%s*%((%d+)%)") or tail:match("GS%s*%(%d+/(%d+)%)")
        or tail:match("iLvl:?%s*(%d+)") or tail:match("%((%d+)%)")
    return {
        race = race, gender = gender, spec = spec, talents = t1 .. "/" .. t2 .. "/" .. t3,
        class = class, level = tonumber(level), gs = tonumber(gs), ilvl = tonumber(ilvl),
    }
end

--- GearScore and item level exactly as the installed GearScoreLite addon computes
--- them for a unit (GearScore_GetScore) - the numbers the native character frame
--- shows - but over the bot's CACHED slot links instead of a live unit, so they
--- work at any distance. The "(a/b)" the bot's own "who" prints after "GS" is a
--- different figure and isn't used. nil when GearScoreLite isn't loaded or no
--- slot data is cached yet.
NS.ArmoryGearScore = function(key, classToken)
    local itemScore = _G["GearScore_GetItemScore"]
    local links = NS.botEquipLinks[key]
    if not itemScore or not links then return nil end

    local gs, count, levelTotal, titan = 0, 0, 0, 1
    local hunter = classToken == "HUNTER"

    local function score(link)
        local ok, value = pcall(itemScore, link)   -- errors on an item the client hasn't cached yet
        if ok and type(value) == "number" then return value end
    end
    local function equipLocOf(link)
        return link and select(9, GetItemInfo(link))
    end

    if links[16] and links[17] and equipLocOf(links[16]) == "INVTYPE_2HWEAPON" then titan = 0.5 end
    if links[17] then
        if equipLocOf(links[17]) == "INVTYPE_2HWEAPON" then titan = 0.5 end
        local value = score(links[17])
        local ilvl = select(4, GetItemInfo(links[17]))
        if value and ilvl then
            if hunter then value = value * 0.3164 end
            gs = gs + value * titan
            count = count + 1
            levelTotal = levelTotal + ilvl
        end
    end
    for i = 1, 18 do
        local link = links[i]
        if i ~= 4 and i ~= 17 and link then
            local value = score(link)
            local ilvl = select(4, GetItemInfo(link))
            if value and ilvl then
                if i == 16 and hunter then value = value * 0.3164 end
                if i == 18 and hunter then value = value * 5.3224 end
                if i == 16 then value = value * titan end
                gs = gs + value
                count = count + 1
                levelTotal = levelTotal + ilvl
            end
        end
    end
    if count == 0 or gs <= 0 then return 0, 0 end
    return math.floor(gs), math.floor(levelTotal / count)
end

--- Paints the armory header under the bot's name from its last "who" data:
---   line 1: "<race> [<gender>], <Class> <level> ур."
---   model's bottom-left corner: "GS: n" / "iLevel: n"; bottom-right (right-aligned): spec / talents
--- Falls back to the roster's own level/class until a "who" reply has landed.
NS.PaintArmoryHeader = function(f)
    local key = strlower(f.botName or "")
    local who = NS.botWho[key]
    local entry = NS.bots[key]
    local className = entry and entry.class
        and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[entry.class] or entry.class)
    if who then
        local female = who.gender == "F"
        local unit = FindBotUnit(f.botName)
        -- Race: the client's own gendered name for the live unit ("Ночная
        -- эльфийка"), else a built-in table, else the bot's English text.
        local raceName = unit and UnitRace(unit)
            or (NS.RACE_RU[who.race] and NS.RACE_RU[who.race][female and 2 or 1]) or who.race
        -- Class: localized name for the right sex (a warrior stays "воин" for
        -- both, a hunter becomes "охотница"), lowercased like the native line.
        local token = (entry and entry.class) or strupper((who.class:gsub(" ", "")))
        local classNames = female and LOCALIZED_CLASS_NAMES_FEMALE or LOCALIZED_CLASS_NAMES_MALE
        local classRu = (classNames and classNames[token]) or who.class
        f.subtitle:SetText(raceName .. ", " .. NS.Utf8LowerFirst(classRu) .. " " .. who.level .. "-го уровня")
        f.specText:SetText(who.spec)
        f.talentsText:SetText(who.talents)
        -- GS / iLevel sit in the model's bottom-left corner, like the native frame.
        local token = (entry and entry.class) or strupper((who.class:gsub(" ", "")))
        local gs, ilvl = NS.ArmoryGearScore(key, token)
        if not gs and not _G["GearScore_GetItemScore"] then gs, ilvl = who.gs, who.ilvl end   -- no GearScoreLite: the bot's own figures
        f.gsText:SetText(gs and ("GS: " .. gs) or "")
        f.ilvlText:SetText(ilvl and ("iLevel: " .. ilvl) or "")
    else
        f.subtitle:SetText(entry and entry.level and className
            and (entry.level .. " ур., " .. className) or "")
        f.specText:SetText("")
        f.talentsText:SetText("")
        f.gsText:SetText("")
        f.ilvlText:SetText("")
    end
end

-- Stores a "who" reply for any tracked bot and refreshes its armory header.
local whoWatcher = CreateFrame("Frame")
whoWatcher:RegisterEvent("CHAT_MSG_WHISPER")
whoWatcher:SetScript("OnEvent", function(self, event, msg, sender)
    local key = strlower(sender or "")
    if not NS.bots[key] then return end
    local plain = NS.CleanEscapes(msg)
    if not (plain:find(" lvl)", 1, true) and plain:find("GS", 1, true)) then return end   -- not a "who" reply
    local who = NS.ParseWhoReply(msg)
    if not who then
        Print("[Who] can't parse: " .. strsub(plain, 1, 200), "armory")
        return
    end
    if not who.gs then
        -- Shape not understood yet: show what the bot actually sent.
        Print("[Who] no GS found in: " .. strsub(plain, 1, 200), "armory")
    end
    NS.botWho[key] = who
    local f = NS.botArmoryFrames[key]
    if f then
        NS.PaintArmoryHeader(f)
        if f:IsShown() then NS.UpdateArmoryModel(f) end
    end
end)

NS.botArmoryFrames = NS.botArmoryFrames or {}   -- lower(name) -> frame, created lazily on first open

--- Builds (once per bot) or returns the existing armory window for
--- `botName`. Each bot gets its OWN frame — mirrors GetOrCreateBagsFrame
--- above — so two bots' armory windows can be open side by side at once.
--- Callers that want to show it must refresh content themselves (see
--- NS.ToggleBotArmory) — this function only constructs the shell.
local function GetOrCreateArmoryFrame(botName)
    local key = strlower(botName)
    local f = NS.botArmoryFrames[key]
    if f then return f end

    local g = PD

    f = CreateFrame("Frame", "AltBotArmory_" .. key, UIParent)
    f.botName = botName
    f:SetWidth(g.frameW)
    f:SetHeight(g.frameH)
    f:SetPoint("CENTER", UIParent, "CENTER", -200, 0)
    f:SetFrameStrata("DIALOG")
    -- Same stacking as the bags windows: the window you click comes to the
    -- front (SetToplevel covers clicks anywhere inside it, OnMouseDown the
    -- non-mouse-enabled bits), and it's fully opaque so one bot's armory
    -- completely hides whatever is behind it (per explicit user direction).
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    NS.RememberWindowPosition(f, "armory", botName)
    f:SetScript("OnMouseDown", function(self) self:Raise() end)

    local fbg = f:CreateTexture(nil, "BACKGROUND")
    fbg:SetAllPoints(f)
    fbg:SetTexture(0, 0, 0, 1)

    local fborder = CreateFrame("Frame", nil, f)
    fborder:SetAllPoints(f)
    fborder:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
    fborder:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    -- Header band (the native frame's portrait/name/level area): name on top,
    -- "<level> level, <class>" under it in the same gold.
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", f, "TOP", 0, -17)
    f.title:SetTextColor(1, 1, 1)

    f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.subtitle:SetPoint("TOP", f.title, "BOTTOM", 0, -4)
    f.subtitle:SetTextColor(1.0, 0.82, 0.0)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() NS.CloseArmory(f) end)

    -- Model + paperdoll equip slots on the native grid.
    f.model = CreateFrame("DressUpModel", "AltBotArmoryModel_" .. key, f)
    f.model:SetSize(g.modelW, g.modelH)
    f.model:SetPoint("TOPLEFT", f, "TOPLEFT", g.modelX, -g.headerH)

    -- Model rotation: two rotate buttons in the model's top-left corner (hold to
    -- keep turning). Buttons only - the model itself doesn't take the mouse (per
    -- explicit user direction), so the window can still be dragged from anywhere.
    f.rotation = 0
    local function ApplyRotation()
        if f.model.SetRotation then f.model:SetRotation(f.rotation) else f.model:SetFacing(f.rotation) end
    end
    f.ApplyRotation = ApplyRotation

    local rotateDir = 0   -- -1 / 0 / +1 while a rotate button is held
    local function MakeRotateButton(offsetX, dir, upTex, downTex)
        local b = CreateFrame("Button", nil, f.model)
        b:SetSize(26, 26)
        b:SetPoint("TOPLEFT", f.model, "TOPLEFT", offsetX, -8)
        b:SetNormalTexture(upTex)
        b:SetPushedTexture(downTex)
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Round", "ADD")
        b:SetScript("OnMouseDown", function() rotateDir = dir end)
        b:SetScript("OnMouseUp", function() rotateDir = 0 end)
        b:SetScript("OnHide", function() rotateDir = 0 end)
        return b
    end
    MakeRotateButton(8, -1, "Interface\\Buttons\\UI-RotationLeft-Button-Up", "Interface\\Buttons\\UI-RotationLeft-Button-Down")
    MakeRotateButton(41, 1, "Interface\\Buttons\\UI-RotationRight-Button-Up", "Interface\\Buttons\\UI-RotationRight-Button-Down")

    f.model:SetScript("OnUpdate", function(self, dt)
        if rotateDir ~= 0 then
            f.rotation = f.rotation + rotateDir * 1.8 * dt   -- ~1.8 rad/s, the native 0.03/frame at 60fps
            ApplyRotation()
        end
    end)

    -- GearScore / item level, bottom-left of the model area as on the native frame.
    f.gsText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.gsText:SetPoint("BOTTOMLEFT", f.model, "BOTTOMLEFT", 6, g.textY + 14)
    f.gsText:SetTextColor(0.8, 0.8, 0.8)
    f.ilvlText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.ilvlText:SetPoint("BOTTOMLEFT", f.model, "BOTTOMLEFT", 6, g.textY)
    f.ilvlText:SetTextColor(0.8, 0.8, 0.8)

    -- Specialization and talent split, two lines in the opposite (bottom-right)
    -- corner, right-aligned. The gap between the right slot column and the text
    -- is the same as the gap GS/iLevel keep from the LEFT slot column (per
    -- explicit user direction): that gap is (model left + 6) - (left column's
    -- right edge), mirrored on the other side.
    local edgeGap = (g.modelX + 6) - (g.leftX + g.slot)
    local specRightOffset = (g.rightX - edgeGap) - (g.modelX + g.modelW)   -- relative to the model's right edge
    f.specText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.specText:SetPoint("BOTTOMRIGHT", f.model, "BOTTOMRIGHT", specRightOffset, g.textY + 14)
    f.specText:SetJustifyH("RIGHT")
    f.specText:SetTextColor(0.8, 0.8, 0.8)
    f.talentsText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.talentsText:SetPoint("BOTTOMRIGHT", f.model, "BOTTOMRIGHT", specRightOffset, g.textY)
    f.talentsText:SetJustifyH("RIGHT")
    f.talentsText:SetTextColor(0.8, 0.8, 0.8)

    f.equipSlots = {}
    for _, eqdef in ipairs(EQUIP_SLOTS) do
        if eqdef.side ~= "bottom" then
            f.equipSlots[eqdef.id] = CreateEquipSlot(f, eqdef, g)
        end
    end

    -- Weapon row: Main Hand, Off Hand, Ranged, Ammo.
    for _, eqdef in ipairs(EQUIP_SLOTS) do
        if eqdef.side == "bottom" then
            local btn = CreateEquipSlot(f, eqdef, g)
            if eqdef.id == 0 then
                -- Smaller Ammo slot, vertically centered on the weapon row, with the
                -- ammo stack count in its corner like the native frame.
                btn.countText = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
                btn.countText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
                btn:SetSize(g.ammoSlot, g.ammoSlot)
                btn:SetPoint("TOPLEFT", f, "TOPLEFT", g.weaponX[eqdef.order],
                    -(g.weaponY + (g.slot - g.ammoSlot) / 2))
            else
                btn:SetPoint("TOPLEFT", f, "TOPLEFT", g.weaponX[eqdef.order], -g.weaponY)
            end
            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(btn)
            bg:SetTexture(eqdef.tex)
            btn.bg = bg
            local icon = btn:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints(btn)
            icon:Hide()
            btn.icon = icon
            btn.slotId   = eqdef.id
            btn.slotName = eqdef.name
            btn:SetScript("OnEnter", function(self) ShowEquipTooltip(f, self) end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            f.equipSlots[eqdef.id] = btn
        end
    end

    -- The native slots' 64x64 "quickslot" frame art over each 37px slot.
    for _, btn in pairs(f.equipSlots) do
        local border = btn:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        border:SetPoint("CENTER", btn, "CENTER", 0, -1)
        border:SetSize(btn:GetWidth() * (64 / 37), btn:GetWidth() * (64 / 37))
    end

    -- (No manual Refresh icon any more, per explicit user direction - opening
    -- the window already fetches fresh equipment, see NS.ToggleBotArmory; the
    -- 4th weapon-row slot is Ammo, like the native frame.)

    -- However the window gets closed (X, board click, Escape...), the equipment
    -- pass ends right there - nothing may keep opening trades with the bot.
    f:SetScript("OnHide", function()
        NS.RestoreArmoryVisible(f)   -- a forced Hide() must not leave it invisible/off screen
        NS.CancelEquipPass(f.botName)
    end)

    f:Hide()
    NS.botArmoryFrames[key] = f
    return f
end

-- ============================================================
-- Item cell right-click context menu — Trade / Sell / Deposit to Guild Bank /
-- Destroy / Open on Wowhead / Cancel, same 6 entries and whisper-trigger
-- style as CleanBot's own bag window (Individual/Inventory.lua's
-- CB_ShowInvMenu): each of Trade/Sell/Deposit/Destroy whispers the bot a
-- single-letter/short trigger word plus the item's link (not its name —
-- mod-playerbots' item commands parse the |Hitem:...|h link, a bare name
-- has no reliable command syntax), per explicit user direction ("верстка
-- сумки должна быть 1 в 1" with CleanBot, "так и в трейде не просто
-- название предмета, а ссылка на предмет"). Trade/Sell/Deposit are hidden
-- for soulbound items (per explicit user direction: "для соулбонд первых
-- трех пунктов меню нет") — a soulbound item can't be traded, vendor-sold,
-- or guild-banked, only destroyed or looked up.
-- ============================================================
local itemCellMenu = CreateFrame("Frame", "AltBotItemCellMenu", UIParent, "UIDropDownMenuTemplate")

--- "t <link>" only actually does anything once a real trade window with that
--- bot is open (confirmed against CleanBot's own Trade.lua: the bot only
--- reacts to "t" while TRADE_SHOW has fired for it — whispering "t" with no
--- trade open is a silent no-op, which is exactly what "выбираю трейд, ничего
--- не происходит" was). So "Trade" in the item menu has to open a real trade
--- (InitiateTrade) FIRST, then send "t <link>" once TRADE_SHOW confirms it's
--- actually open with THIS bot — not just fire the whisper on click.
local pendingTradeOffer = nil   -- { key = lower(botName), link = string } | nil
local tradeShowWatcher = CreateFrame("Frame")
tradeShowWatcher:RegisterEvent("TRADE_SHOW")
tradeShowWatcher:SetScript("OnEvent", function()
    if not pendingTradeOffer then return end
    local recipientName = TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText()
    if recipientName and strlower(recipientName) == pendingTradeOffer.key then
        SendBotCommand(recipientName, "t " .. pendingTradeOffer.link)
    end
    pendingTradeOffer = nil
end)

--- Returns the clean API item link for a raw item link (which may carry
--- color codes and extra enchant/gem fields that confuse the server-side
--- command parser) — mirrors CleanBot's own NS.CB_CleanItemLink
--- (Bridge.lua). cell.itemLink comes straight out of a bot's "items" whisper
--- reply as-is; mod-playerbots' whisper commands (t/s/guild bank/destroy)
--- need the canonical client-cache link instead, or they silently no-op
--- (confirmed by the user in-game: clicking Trade sent the command but
--- nothing happened on the bot's end).
local function CleanItemLink(rawLink)
    local itemId = rawLink:match("item:(%d+)")
    local _, apiLink = GetItemInfo(tonumber(itemId) or 0)
    return apiLink or rawLink
end

--- Scans an item's tooltip for the client's own localized "Soulbound" string
--- (ITEM_SOULBOUND — a FrameXML global, so this reads correctly in any
--- client locale including Russian). WoW's item APIs (GetItemInfo etc.)
--- don't expose bind status directly in 3.3.5 — a hidden scanning tooltip
--- is the standard way to read it. Cached per item link within one menu
--- open (soulbound status doesn't change while the menu is up).
local itemScanTooltip = CreateFrame("GameTooltip", "AltBotItemScanTooltip", nil, "GameTooltipTemplate")
itemScanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
local function IsItemSoulbound(link)
    if not link or not ITEM_SOULBOUND then return false end
    itemScanTooltip:ClearLines()
    itemScanTooltip:SetHyperlink(link)
    for i = 1, itemScanTooltip:NumLines() do
        local line = _G["AltBotItemScanTooltipTextLeft" .. i]
        local text = line and line:GetText()
        if text == ITEM_SOULBOUND then return true end
    end
    return false
end

-- GetItemInfo's 6th return (itemType) is localized text ("Задания" on a
-- Russian client, confirmed in-game via /script dump) — never compare it
-- against an English literal. GetAuctionItemClasses() returns the same
-- item-class names in the client's own locale in fixed order; its 12th
-- return is always the "quest" class name, confirmed matching in-game
-- ("Задания" == "Задания"). An NS. field (not local) so it's usable from
-- PaintBagsFrame, which is defined earlier in the file than this point —
-- same forward-reference reasoning as NS.bagsSessionSoldLinks elsewhere.
local questItemTypeToken
NS.IsQuestItemLink = function(link)
    if not link then return false end
    if not questItemTypeToken then
        local _, _, _, _, _, _, _, _, _, _, _, quest = GetAuctionItemClasses()
        if quest then questItemTypeToken = quest end
    end
    local _, _, _, _, _, itemType = GetItemInfo(link)
    return itemType ~= nil and itemType == questItemTypeToken
end

--- Colors/shows or hides a bags-window cell's quality border (cell.border —
--- see its own doc comment at creation, GetOrCreateBagsFrame). Quest items
--- get the gold quest-item color regardless of their (usually Common/grey)
--- actual quality; otherwise Uncommon+ items get their real quality color
--- (GetItemQualityColor — green/blue/purple/orange/etc, same colors the
--- client's own tooltips and bag slots use); Poor/Common items and empty
--- cells show no border at all, same as native bag slots.
NS.ApplyItemBorder = function(cell, link)
    if not link then
        cell.border:Hide()
        return
    end
    if NS.IsQuestItemLink(link) then
        cell.border:SetBackdropBorderColor(1.0, 0.82, 0.0, 1)
        cell.border:Show()
        return
    end
    local _, _, quality = GetItemInfo(link)
    if not quality or quality < 2 then
        cell.border:Hide()
        return
    end
    local r, g, b = GetItemQualityColor(quality)
    cell.border:SetBackdropBorderColor(r, g, b, 1)
    cell.border:Show()
end

--- Optimistically empties one item's OWN cell in a bot's bags window right
--- away — Trade/Sell/Deposit/Destroy all remove the WHOLE stack that cell
--- held (mod-playerbots' "s"/"gb"/"destroy" triggers take a link, not a
--- count, so they always act on the entire stack in that slot, never a
--- partial one), so the cell just empties immediately rather than waiting
--- for the next "items" refresh. Per explicit user direction: "после
--- трейда, селла, депозита, дестроя, предмет сразу должен удаляться из
--- сумки" — and specifically NOT shifting every later item down a slot to
--- fill the gap ("не надо остальные шмотки сдвигать, на месте проданой/
--- отданой шмотки остается пустой слот"): sets that one index to nil
--- in-place (leaving a hole in f.items) instead of table.remove, which
--- would shift everything after it. Matched by cell.itemLink (the exact
--- link this specific cell is showing), not just item id, since two cells
--- for the same item can coexist.
local function RemoveBagsItemOptimistically(botName, itemLink)
    local key = strlower(botName)
    local f = NS.botBagsFrames[key]
    if not f or not f.items then return end
    -- Remembers this link as sold/traded away THIS session — see
    -- MergeBagsUpdate's own doc comment for why: a background "items" reply
    -- that still lists this item (the server just hasn't caught up to this
    -- action yet) must not resurrect it into the cache.
    NS.bagsSessionSoldLinks[key] = NS.bagsSessionSoldLinks[key] or {}
    NS.bagsSessionSoldLinks[key][itemLink] = true
    -- Walks 1..f.itemsMaxIndex, NOT ipairs/# on f.items — once a hole exists
    -- from an earlier removal, both of those become unreliable (ipairs stops
    -- at the first nil; # is undefined on a table with holes).
    for i = 1, (f.itemsMaxIndex or #f.items) do
        local item = f.items[i]
        if item and item.link == itemLink then
            f.items[i] = nil
            break
        end
    end
    local rosterEntry = NS.bots[key]
    PaintBagsFrame(botName, f.items,
        rosterEntry and rosterEntry.bagTotal,
        rosterEntry and rosterEntry.bagFree,
        rosterEntry and rosterEntry.money)
end

--- A purchase made FOR a bot at the vendor (see the wrapped BuyMerchantItem): the bot's gold goes down
--- and the item appears in its bags cache (and in its bags window, if open) at once, before the next
--- "stats"/"items" replies confirm it - per explicit user direction.
NS.AddBagsItemOptimistically = function(botName, itemLink, count, copperSpent)
    local key = strlower(botName)
    local entry = NS.bots[key]
    if entry and entry.money and copperSpent and copperSpent > 0 then
        local total = entry.money.gold * 10000 + entry.money.silver * 100 + entry.money.copper
        total = math.max(0, total - copperSpent)
        entry.money = { gold = math.floor(total / 10000), silver = math.floor((total % 10000) / 100), copper = total % 100 }
    end
    AltBot_SavedVars.bagsCache = AltBot_SavedVars.bagsCache or {}
    local cache = AltBot_SavedVars.bagsCache[key]
    if not cache then
        cache = {}
        AltBot_SavedVars.bagsCache[key] = cache
    end
    -- The "items" list has ONE entry per item whatever its count, while the real slots follow the server's
    -- own stack sizes (flax cloth lies 90 to a stack there, the client says 20), so the free-slot number
    -- is NOT guessed here: "stats" has it right and is asked for right after the purchase (see the wrapped
    -- BuyMerchantItem). Here: the same item (same item id - the vendor's link and the bot's own link differ
    -- in their tail fields) gets its count raised, a new item takes the first hole (or the tail).
    local itemId = tonumber((itemLink or ""):match("item:(%d+)"))
    local maxIndex, existing, hole = 0, nil, nil
    for i in pairs(cache) do
        if i > maxIndex then maxIndex = i end
    end
    for i = 1, maxIndex do
        local item = cache[i]
        if item == nil then
            hole = hole or i
        elseif tonumber((item.link or ""):match("item:(%d+)")) == itemId then
            existing = item
            break
        end
    end
    if existing then
        existing.count = (existing.count or 1) + count
    else
        cache[hole or (maxIndex + 1)] = { link = itemLink, count = count }
    end
    local f = NS.botBagsFrames[key]
    if f then
        f.items = cache
        local newMax = 0
        for i in pairs(cache) do
            if i > newMax then newMax = i end
        end
        f.itemsMaxIndex = newMax
        PaintBagsFrame(botName, cache, entry and entry.bagTotal, entry and entry.bagFree, entry and entry.money)
    end
    if NS.RefreshPanel then NS.RefreshPanel() end
end

--- Walks up a cell's parent chain to the first frame carrying a .botName —
--- each independent per-bot bags window (GetOrCreateBagsFrame parents cells
--- directly to the frame that carries .botName) works this way. Walking the
--- chain rather than reading NS.botDetailFrame unconditionally avoids ever
--- sending commands to the wrong bot. Shared by the right-click menu and the
--- left-click trade shortcut below.
local function FindCellBotName(cell)
    local f = cell:GetParent()
    while f do
        if f.botName then return f.botName end
        f = f.GetParent and f:GetParent() or nil
    end
    return nil
end

--- Left-click shortcut: Trade or Sell the clicked item, whichever the bags
--- window's own footer toggle (f.leftClickMode, see GetOrCreateBagsFrame's
--- toggle UI) is currently set to — default Trade. Per explicit user
--- direction: a 2-position radio toggle between the slot count and money
--- labels picks what left-click does; no auto-refresh afterward at all (see
--- this function's own closing comment) — the window only re-syncs with the
--- server when it's closed (NS.ToggleBotBags' own close path).
---
--- A complete no-op in Farm mode — unless this bot was individually summoned
--- and is tradeable right now (NS.CanWorkBotBags) — a grinding bot has no
--- vendor/trade partner reachable, so both Trade and Sell would just go nowhere. Per
--- explicit user direction: "убери умничание с отложеной продажей, если мы
--- в режиме фарм, то нельзя ни продавать ни трейдовать... в режиме фарм в
--- сумки ботов можно только смотреть" — Farm mode's bags window is
--- view-only; switch to Quest mode to actually work the bags, then back.
---
--- Trade: if a trade window is already open with this exact bot, just send
--- "t <link>" straight away (adds it to the open trade); otherwise open a
--- fresh trade first and let tradeShowWatcher send "t <link>" once
--- TRADE_SHOW confirms it's open with this bot (same two-step flow the
--- menu's own "Trade" entry uses — "t" is a silent no-op with no trade
--- window open).
NS.TradeCellItem = function(cell)
    if not cell.itemLink then return end
    local botName = FindCellBotName(cell)
    if not botName then return end
    if not NS.CanWorkBotBags(botName) then return end   -- Farm: view-only unless individually summoned
    local link = CleanItemLink(cell.itemLink)
    if IsItemSoulbound(link) then return end

    local f = cell:GetParent()
    local sellMode = f and f.leftClickMode == "sell"

    if sellMode then
        SendBotCommand(botName, "s " .. link)
    else
        local key = strlower(botName)
        local recipientName = TradeFrame and TradeFrame:IsShown() and TradeFrameRecipientNameText
            and TradeFrameRecipientNameText:GetText()
        if recipientName and strlower(recipientName) == key then
            SendBotCommand(botName, "t " .. link)
        else
            pendingTradeOffer = { key = key, link = link }
            InitiateTrade(botName)
        end
    end
    -- No "items" re-fetch here, or anywhere else in this window, any more —
    -- per explicit user direction ("после продажи/отдачи не надо запрашивать
    -- апдейт сумки с сервера, запрос апдейта происходит в момент закрытия
    -- окна сумки"). If the action never actually goes through server-side,
    -- the cell stays wrong until the window is closed and reopened — an
    -- accepted tradeoff for not hammering the bot with a fetch per click.
    RemoveBagsItemOptimistically(botName, cell.itemLink)
end

--- Opens the right-click context menu for an item cell. A complete no-op in
--- Farm mode — see NS.TradeCellItem's own doc comment for why: the bags
--- window is view-only while grinding, every entry here (Trade/Sell/Equip/
--- Deposit/Destroy) requires a reachable vendor/trade partner.
NS.ShowItemCellMenu = function(cell)
    if not cell.itemLink then return end
    local botName = FindCellBotName(cell)
    if not botName then return end
    if not NS.CanWorkBotBags(botName) then return end   -- Farm: view-only unless individually summoned
    -- Cleaned once here — the raw link off a whisper reply carries color
    -- codes/extra fields the server-side command parser chokes on silently
    -- (see CleanItemLink's own doc comment).
    local link = CleanItemLink(cell.itemLink)
    local soulbound = IsItemSoulbound(link)

    UIDropDownMenu_Initialize(itemCellMenu, function()
        local info = UIDropDownMenu_CreateInfo()
        info.notCheckable = true

        if not soulbound then
            -- Chat commands are TRIGGERS, not action names (same mod-
            -- playerbots convention CleanBot's own doc comment notes) — "t"
            -- for trade, "s" for sell, "guild bank" for guild-bank deposit.
            -- No "items" re-fetch after any of these any more — per explicit
            -- user direction, the bags window only re-syncs with the server
            -- when it's closed (see NS.ToggleBotBags' own close path), never
            -- after an individual action.
            info.text = "Sell"
            info.func = function()
                SendBotCommand(botName, "s " .. link)
                RemoveBagsItemOptimistically(botName, cell.itemLink)
            end
            UIDropDownMenu_AddButton(info)

            info.text = "Trade"
            info.func = function()
                -- Opens a real trade window with the bot; tradeShowWatcher
                -- (above) sends "t <link>" once TRADE_SHOW confirms it's
                -- actually open with this bot — see that watcher's own doc
                -- comment for why "t" can't just be whispered on its own.
                pendingTradeOffer = { key = strlower(botName), link = link }
                InitiateTrade(botName)
                RemoveBagsItemOptimistically(botName, cell.itemLink)
            end
            UIDropDownMenu_AddButton(info)

            info.text = "Equip"
            info.func = function()
                SendBotCommand(botName, "e " .. link)
                RemoveBagsItemOptimistically(botName, cell.itemLink)
            end
            UIDropDownMenu_AddButton(info)

            info.text = "Deposit"
            info.func = function()
                SendBotCommand(botName, "guild bank " .. link)
                RemoveBagsItemOptimistically(botName, cell.itemLink)
            end
            UIDropDownMenu_AddButton(info)
        end

        info.text = "Destroy"
        info.func = function()
            SendBotCommand(botName, "destroy " .. link)
            RemoveBagsItemOptimistically(botName, cell.itemLink)
        end
        UIDropDownMenu_AddButton(info)

        -- Wowhead can't be opened directly from an addon (URL access is
        -- restricted) — same limitation CleanBot's own Wowhead menu entry
        -- works around by showing a copyable link in chat instead of trying
        -- to launch a browser.
        info.text = "Wowhead"
        info.func = function()
            local itemId = link:match("item:(%d+)")
            if itemId then
                Print("Wowhead: https://www.wowhead.com/wotlk/item=" .. itemId, "inventory")
            end
        end
        UIDropDownMenu_AddButton(info)

        info.text = "Cancel"
        info.func = function() CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)
    end, "MENU")
    ToggleDropDownMenu(1, nil, itemCellMenu, "cursor", 0, 0)   -- opens under the cursor
end

-- ============================================================
-- Strategy panel rendering + fetch/toggle. Per-bot cached state:
-- NS.botStrategyState[key] = { combat = {field=bool}, nonCombat = {field=bool} }
-- ============================================================
NS.botStrategyState = NS.botStrategyState or {}

-- ============================================================
-- Strategy window - a fully independent, per-bot frame (same shell as the
-- bags/armory windows: own frame registry, opaque backdrop, raise-on-click,
-- paint-before-show, self-fetches its own "co ?"/"nc ?" whispers on open),
-- laid out like CleanBot's strategy panel, per explicit user direction:
-- exclusive DROPDOWNS (Role with its Tank/Healer/DPS sub-sections, Targeting,
-- Movement, Distance, Rotation...), checkboxes and the Delay slider.
-- Combat groups are balanced over two columns, Non-Combat is the third.
--
-- The widget tree is built ONCE per window (first open - the bot's class is
-- known by then, which decides class-only entries and per-class tokens);
-- every later update just re-reads NS.botStrategyState through the
-- f.refreshers closures. (The old version re-created every checkbox on every
-- reply; WoW never frees frames, so that leaked.)
-- ============================================================
NS.botStrategyFrames = NS.botStrategyFrames or {}   -- lower(name) -> frame, created lazily on first open

local STRAT_COL_W  = 190   -- width of one column
local STRAT_ROW_H  = 20    -- checkbox row
local STRAT_HEAD_H = 16    -- group header
local STRAT_DD_H   = 30    -- one dropdown control
local STRAT_GAP    = 6     -- between groups

-- The DPS rotation token to give a bot that was just switched to the "DPS"
-- role (a tank/heal role replaced its damage rotation, so clearing the role
-- alone would leave it with none): by the spec its "who" reported, falling
-- back to a per-class default (mirrors CleanBot's SPEC_DPS_TOKEN tables).
NS.DPS_TOKEN_BY_SPEC = {
    WARRIOR     = { arms = "arms", fury = "fury", protection = "arms", default = "arms" },
    PALADIN     = { default = "dps" },
    PRIEST      = { default = "dps" },
    SHAMAN      = { elemental = "ele", enhancement = "enh", restoration = "ele", default = "ele" },
    WARLOCK     = { affliction = "affli", demonology = "demo", destruction = "destro", default = "destro" },
    DRUID       = { balance = "balance", ["feral combat"] = "cat", restoration = "balance", default = "cat" },
    DEATHKNIGHT = { frost = "frost", unholy = "unholy", blood = "frost", default = "frost" },
}

--- The command token to send for `s` for a bot of `class` (a few roles use
--- another token for some classes, e.g. a druid tanks as "bear").
NS.StrategyCmd = function(s, class)
    return (s.cmdByClass and class and s.cmdByClass[class]) or s.cmd
end

--- Whether entry `s` applies to a bot of `class` (class-only entries show
--- only for that class; with an unknown class they're left out).
NS.StrategyShown = function(s, class)
    return not s.classOnly or s.classOnly == class
end

--- Who a strategy window's changes go to: its own bot, or - for the GROUP window opened from
--- the master's name on the board (f.group) - every tracked bot currently in the group. Per
--- explicit user direction: the same form, but applied to all bots.
NS.StrategyTargets = function(f)
    if not f.group then
        return { NS.bots[f.key] or { name = f.botName, class = f.class } }
    end
    local grouped = {}
    ForEachGroupMember(function(_, name)
        if name then grouped[strlower(name)] = true end
    end)
    local list = {}
    for _, key in ipairs(NS.rosterOrder) do
        local entry = NS.bots[key]
        if entry and grouped[key] then list[#list + 1] = entry end
    end
    return list
end

--- Sends `build(entry)` (a command string or nil) to every target of window `f`.
NS.StratSend = function(f, build)
    for _, entry in ipairs(NS.StrategyTargets(f)) do
        local cmd = build(entry)
        if cmd then SendBotCommand(entry.name, cmd) end
    end
end

--- NS.SetStrategyField for every target of window `f`.
NS.StratSetField = function(f, isCombat, field, value)
    for _, entry in ipairs(NS.StrategyTargets(f)) do
        NS.SetStrategyField(strlower(entry.name), isCombat, field, value)
    end
end

--- The group window's displayed state, merged from the bots' own cached states: a boolean
--- is true if it is on for EVERY target, "mixed" if for some; a number/text value shows only if all targets
--- agree.
NS.GroupStrategyState = function(f)
    local targets = NS.StrategyTargets(f)
    local result = { combat = {}, nonCombat = {} }
    local function merge(getter, dst)
        local seen = {}
        for _, e in ipairs(targets) do
            local src = getter(NS.botStrategyState[strlower(e.name)])
            for field in pairs(src or {}) do seen[field] = true end
        end
        for field in pairs(seen) do
            local first, same, allTrue, anyTrue, isBool = true, true, true, false, false
            local value
            for _, e in ipairs(targets) do
                local src = getter(NS.botStrategyState[strlower(e.name)])
                local x = src and src[field]
                if type(x) == "boolean" then isBool = true end
                if x ~= true then allTrue = false else anyTrue = true end
                if first then value, first = x, false elseif x ~= value then same = false end
            end
            -- on for all = true, for none = false, for some = "mixed" (shown white with a "*")
            if isBool then
                dst[field] = allTrue or (anyTrue and "mixed" or false)
            elseif same then
                dst[field] = value
            end
        end
    end
    merge(function(st) return st and st.combat end, result.combat)
    merge(function(st) return st and st.nonCombat end, result.nonCombat)
    local loot
    for i, e in ipairs(targets) do
        local st = NS.botStrategyState[strlower(e.name)]
        local x = st and st.lootStrategy
        if i == 1 then loot = x elseif x ~= loot then loot = nil end
    end
    result.lootStrategy = loot
    return result
end

--- Writes one strategy field into the cached state (optimistic: mod-playerbots
--- gives no confirmation reply for these commands).
NS.SetStrategyField = function(key, isCombat, field, value)
    local section = isCombat and "combat" or "nonCombat"
    NS.botStrategyState[key] = NS.botStrategyState[key] or {}
    NS.botStrategyState[key][section] = NS.botStrategyState[key][section] or {}
    NS.botStrategyState[key][section][field] = value
end

--- Exclusive selection among `list` (the options of one dropdown): `selected`
--- (an entry of the list) becomes the active one - one "+cmd", the server drops
--- its siblings itself - or nil clears the group: every currently-on member gets
--- a "-cmd" (all of them if the state isn't known yet). afterNone, if given, runs
--- after a clear (the Role dropdown re-adds a damage rotation there).
NS.ApplyExclusive = function(f, isCombat, list, selected, afterNone)
    local prefix = isCombat and "co " or "nc "
    if selected then
        NS.StratSend(f, function(e) return prefix .. "+" .. NS.StrategyCmd(selected, e.class) end)
    else
        for _, e in ipairs(NS.StrategyTargets(f)) do
            local st = NS.botStrategyState[strlower(e.name)]
            local state = st and st[isCombat and "combat" or "nonCombat"]
            for _, s in ipairs(list) do
                if not state or state[s.field] then
                    SendBotCommand(e.name, prefix .. "-" .. NS.StrategyCmd(s, e.class))
                end
            end
        end
        if afterNone then afterNone() end
    end
    for _, s in ipairs(list) do
        NS.StratSetField(f, isCombat, s.field, selected ~= nil and s == selected)
    end
end

--- One exclusive dropdown control inside `parent` at (x, y). `list` = options
--- (already class-filtered), `noneLabel` = the entry/label for "none of them",
--- `onChosen(entry|nil)` does the work (usually NS.ApplyExclusive). Returns the
--- frame; its .Refresh() resyncs the displayed text from the cached state.
--- `blank` (the Role dropdown of the group window): disabled and always empty.
local function CreateStrategyDropdown(f, parent, x, y, width, list, noneLabel, isCombat, onChosen, blank)
    f.ddCount = (f.ddCount or 0) + 1
    local dd = CreateFrame("Frame", "AltBotStratDD_" .. f.key .. "_" .. f.ddCount, parent, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 16, y)   -- the template's own hit area is inset ~16px
    UIDropDownMenu_SetWidth(dd, width - 36)

    local function current()
        local state = f:State(isCombat)
        for _, s in ipairs(list) do
            if state and state[s.field] == true then return s end
        end
    end
    dd.Refresh = function()
        if blank then
            UIDropDownMenu_SetText(dd, "")
            UIDropDownMenu_DisableDropDown(dd)
            return
        end
        local cur = current()
        local text = cur and cur.name or noneLabel
        if not cur then
            local state = f:State(isCombat)
            for _, s in ipairs(list) do
                if state and state[s.field] == "mixed" then text = "Mixed*" break end
            end
        end
        UIDropDownMenu_SetText(dd, text)
    end
    UIDropDownMenu_Initialize(dd, function()
        local cur = current()
        local none = UIDropDownMenu_CreateInfo()
        none.text = noneLabel
        none.checked = cur == nil
        none.func = function()
            onChosen(nil)
            dd.Refresh()
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(none)
        for _, s in ipairs(list) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = s.name
            info.checked = cur == s
            info.func = function()
                onChosen(s)
                dd.Refresh()
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    f.refreshers[#f.refreshers + 1] = dd.Refresh
    return dd
end

--- The Delay slider (1..max) with its value box, bound to strategy `s`
--- (a timerSlider entry): sends "<co|nc> <cmd> <N>" on commit (drag release or
--- Enter in the box); greyed out while the strategy it `dependsOn` is off.
local function CreateStrategySlider(f, parent, x, y, width, s, isCombat)
    f.sliderCount = (f.sliderCount or 0) + 1
    local name = "AltBotStratSlider_" .. f.key .. "_" .. f.sliderCount
    local wrap = CreateFrame("Frame", nil, parent)
    wrap:SetSize(width, 40)
    wrap:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local label = wrap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", wrap, "TOPLEFT", 0, 0)
    label:SetText(s.name)
    label:SetTextColor(1, 1, 1)

    local box = CreateFrame("EditBox", nil, wrap, "InputBoxTemplate")
    box:SetSize(34, 18)
    box:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", -4, -2)
    box:SetAutoFocus(false)
    box:SetJustifyH("CENTER")

    local slider = CreateFrame("Slider", name, wrap, "OptionsSliderTemplate")
    slider:SetHeight(17)
    slider:SetPoint("TOPLEFT", wrap, "TOPLEFT", 0, -22)
    slider:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", -4, -22)
    slider:SetMinMaxValues(s.min, s.max)
    slider:SetValueStep(1)
    if _G[name .. "Low"] then _G[name .. "Low"]:SetText("") end
    if _G[name .. "High"] then _G[name .. "High"]:SetText("") end
    if _G[name .. "Text"] then _G[name .. "Text"]:SetText("") end

    local function commit(v)
        v = math.max(s.min, math.min(s.max, math.floor(v + 0.5)))
        NS.StratSend(f, function() return (isCombat and "co " or "nc ") .. s.cmd .. " " .. v end)
        NS.StratSetField(f, isCombat, s.field, v)
    end
    slider:SetScript("OnValueChanged", function(self, v)
        if self.silent then return end
        box:SetText(tostring(math.floor(v + 0.5)))
    end)
    slider:SetScript("OnMouseUp", function(self) commit(self:GetValue()) end)
    box:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText())
        if v then
            slider:SetValue(v)
            commit(v)
        end
        self:ClearFocus()
    end)
    box:SetScript("OnEscapePressed", box.ClearFocus)

    f.refreshers[#f.refreshers + 1] = function()
        local state = f:State(isCombat)
        local v = (state and tonumber(state[s.field])) or s.min
        slider.silent = true
        slider:SetValue(v)
        slider.silent = false
        box:SetText(tostring(math.floor(v + 0.5)))
        local enabled = not s.dependsOn or (state and state[s.dependsOn])
        if enabled then slider:Enable(); box:Enable() else slider:Disable(); box:Disable() end
    end
    return wrap
end

--- Builds a list of entries (checkboxes, inline dropdown bundles, sliders)
--- downward from (x, y) inside `parent`. Returns the HEIGHT used (positive).
local function BuildStrategyEntries(f, parent, x, y, entries, isCombat)
    local top = y
    local prefix = isCombat and "co " or "nc "
    for _, s in ipairs(entries) do
        if NS.StrategyShown(s, f.class) then
            if s.type == "dropdown" then
                local head = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                head:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
                head:SetText(s.header)
                head:SetTextColor(0.8, 0.8, 0.8)
                y = y - 14
                local list = {}
                for _, o in ipairs(s.strategies) do
                    if NS.StrategyShown(o, f.class) then list[#list + 1] = o end
                end
                CreateStrategyDropdown(f, parent, x, y, STRAT_COL_W - 6, list, s.noneLabel, isCombat,
                    function(sel) NS.ApplyExclusive(f, isCombat, list, sel) end)
                y = y - STRAT_DD_H
            elseif s.type == "timerSlider" then
                CreateStrategySlider(f, parent, x, y, STRAT_COL_W - 6, s, isCombat)
                y = y - 40
            elseif s.cmd and s.field then
                local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
                check:SetSize(STRAT_ROW_H, STRAT_ROW_H)
                check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
                local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                label:SetPoint("LEFT", check, "RIGHT", 2, 0)
                label:SetText(s.name)
                label:SetTextColor(1, 1, 1)
                check:SetScript("OnClick", function(self)
                    local on = self:GetChecked() and true or false
                    NS.StratSend(f, function(e) return prefix .. (on and "+" or "-") .. NS.StrategyCmd(s, e.class) end)
                    NS.StratSetField(f, isCombat, s.field, on)
                    f:RefreshStrategies()   -- dependent controls (the Delay slider) follow at once
                end)
                f.refreshers[#f.refreshers + 1] = function()
                    local state = f:State(isCombat)
                    local v = state and state[s.field]
                    -- Group window, on for some bots only: a WHITE check and a "*" after the label
                    -- (clicking it turns the strategy off for everyone).
                    local mixed = v == "mixed"
                    check:SetChecked(v and true or false)
                    local tex = check:GetCheckedTexture()
                    if tex then tex:SetDesaturated(mixed and true or false) end
                    label:SetText(mixed and (s.name .. "*") or s.name)
                end
                y = y - STRAT_ROW_H
            end
        end
    end
    return top - y
end

--- A tinted panel behind a block of controls (CleanBot's grouped look).
local function StrategyPanel(parent, x, y, height)
    local bg = parent:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 3, y + 2)
    bg:SetSize(STRAT_COL_W + 2, height + 4)
    bg:SetTexture(1, 1, 1, 0.05)
    return bg
end

--- A group header in CleanBot's gold.
local function StrategyGroupHeader(col, y, text)
    local head = col:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    head:SetPoint("TOPLEFT", col, "TOPLEFT", 0, y)
    head:SetText(text)
    head:SetTextColor(1, 0.82, 0)
    return head
end

--- A queried command SETTING shown as a dropdown (not a co/nc strategy): the
--- Loot Quality group - sends "<cmd> <value>" ("ll normal") and reads the bot's
--- "Loot strategy: <mode>" reply (cached in the state table's top level).
local function BuildStrategySettingDropdown(f, col, y, grp)
    f.ddCount = (f.ddCount or 0) + 1
    local dd = CreateFrame("Frame", "AltBotStratDD_" .. f.key .. "_" .. f.ddCount, col, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", col, "TOPLEFT", -16, y)
    UIDropDownMenu_SetWidth(dd, STRAT_COL_W - 42)
    local nameByValue = {}
    for _, o in ipairs(grp.options) do nameByValue[o.value] = o.name end
    local function current()
        local st = f.group and (f.groupCache or NS.GroupStrategyState(f)) or NS.botStrategyState[f.key]
        return st and st[grp.field]
    end
    dd.Refresh = function()
        UIDropDownMenu_SetText(dd, nameByValue[current()] or "Select...")
    end
    UIDropDownMenu_Initialize(dd, function()
        local cur = current()
        for _, o in ipairs(grp.options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = o.name
            info.checked = cur == o.value
            info.func = function()
                NS.StratSend(f, function() return grp.cmd .. " " .. o.value end)
                for _, e in ipairs(NS.StrategyTargets(f)) do
                    local k = strlower(e.name)
                    NS.botStrategyState[k] = NS.botStrategyState[k] or {}
                    NS.botStrategyState[k][grp.field] = o.value
                end
                dd.Refresh()
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    f.refreshers[#f.refreshers + 1] = dd.Refresh
    return y - STRAT_DD_H
end

--- The Role group, phase 1: header + the Role dropdown ("DPS" = no role). The
--- sub-sections for the active role (Tank / Healing / DPS options) are drawn by
--- the returned buildSubs(col, y) - CleanBot puts them under the NEXT group
--- (Targeting), so the Role and Targeting dropdowns sit right after each other.
--- buildSubs returns the y below the reserved height of the tallest sub-section.
--- Returns the new y after the dropdown, and buildSubs.
local function BuildStrategyRoleGroup(f, col, y, grp, isCombat)
    StrategyGroupHeader(col, y, grp.header)
    y = y - STRAT_HEAD_H

    local roles = {}
    for _, s in ipairs(grp.strategies) do
        if NS.StrategyShown(s, f.class) then roles[#roles + 1] = s end
    end

    local sections, roleSection, noneSection = {}, {}, nil
    local function showSection()
        local state = f:State(isCombat)
        local active
        for _, s in ipairs(roles) do
            if state and state[s.field] == true then active = s.field; break end
        end
        for _, sec in ipairs(sections) do sec:Hide() end
        local sec = (active and roleSection[active]) or noneSection
        if sec then sec:Show() end
    end

    -- Picking "DPS" clears the role; the bot lost its damage rotation when it
    -- became tank/healer, so give it one back (by spec, else the class default).
    local function addDpsToken()
        NS.StratSend(f, function(e)
            local map = NS.DPS_TOKEN_BY_SPEC[e.class]
            if not map then return nil end
            local who = NS.botWho[strlower(e.name)]
            local spec = who and who.spec and strlower(who.spec)
            local token = (spec and map[spec]) or (grp.dpsCmdByClass and grp.dpsCmdByClass[e.class]) or map.default
            return token and ("co +" .. token) or nil
        end)
    end

    CreateStrategyDropdown(f, col, 0, y, STRAT_COL_W - 6, roles, grp.noneLabel, isCombat,
        function(sel)
            NS.ApplyExclusive(f, isCombat, roles, sel, addDpsToken)
            showSection()
        end, f.group)   -- roles differ per bot by nature: not processed in the group window
    y = y - STRAT_DD_H - STRAT_GAP

    local function buildSubs(subCol, subY)
        local maxH = 0
        for _, sg in ipairs(grp.subGroups) do
            local sec = CreateFrame("Frame", nil, subCol)
            sec:SetPoint("TOPLEFT", subCol, "TOPLEFT", 0, subY)
            sec:SetSize(STRAT_COL_W, 1)
            local h = BuildStrategyEntries(f, sec, 0, 0, sg.strategies, isCombat)
            sec:SetHeight(math.max(h, 1))
            local bg = sec:CreateTexture(nil, "BACKGROUND")
            bg:SetPoint("TOPLEFT", sec, "TOPLEFT", -3, 2)
            bg:SetSize(STRAT_COL_W + 2, h + 4)
            bg:SetTexture(1, 1, 1, 0.05)
            sec:Hide()
            sections[#sections + 1] = sec
            maxH = math.max(maxH, h)
            if sg.none then noneSection = sec end
            for _, rf in ipairs(sg.roles or { sg.field }) do roleSection[rf] = sec end
        end
        f.refreshers[#f.refreshers + 1] = showSection
        return subY - maxH - STRAT_GAP
    end
    return y, buildSubs
end

--- Builds every group of one strategy list into its columns. `cols` =
--- { left = {frame, y}, right = {frame, y} }; a group goes to the column named
--- by its `column` field (CleanBot's own left/right assignment), else the
--- shorter one. A Role group with `subAfter` draws its sub-sections right below
--- the group of that name.
local function BuildStrategyGroups(f, groups, cols, isCombat)
    local pending   -- { after = groupKey, build = fn, col = column record } for a deferred Role sub-section
    for _, grp in ipairs(groups) do
        local c = cols[grp.column or ""]
        if not c then
            c = cols.left
            if cols.right.y > c.y then c = cols.right end   -- y is negative: larger = less used
        end
        local col, y = c.frame, c.y
        if grp.type == "roleDropdown" then
            local newY, buildSubs = BuildStrategyRoleGroup(f, col, y, grp, isCombat)
            if grp.subAfter then
                pending = { after = grp.subAfter, build = buildSubs, col = c }
                c.y = newY
            else
                c.y = buildSubs(col, newY)
            end
        elseif grp.type == "settingDropdown" then
            StrategyGroupHeader(col, y, grp.header)
            c.y = BuildStrategySettingDropdown(f, col, y - STRAT_HEAD_H, grp) - STRAT_GAP
        else
            StrategyGroupHeader(col, y, grp.header)
            y = y - STRAT_HEAD_H
            if grp.type == "dropdown" then
                local list = {}
                for _, o in ipairs(grp.strategies) do
                    if NS.StrategyShown(o, f.class) then list[#list + 1] = o end
                end
                CreateStrategyDropdown(f, col, 0, y, STRAT_COL_W - 6, list, grp.noneLabel, isCombat,
                    function(sel) NS.ApplyExclusive(f, isCombat, list, sel) end)
                y = y - STRAT_DD_H
            else
                local h = BuildStrategyEntries(f, col, 0, y, grp.strategies, isCombat)
                StrategyPanel(col, 0, y, h)
                y = y - h
            end
            c.y = y - STRAT_GAP
        end
        -- The group the Role sub-sections wait for just got built: draw them under it.
        if pending and grp.group == pending.after then
            c.y = pending.build(c.frame, c.y)
            pending = nil
        end
    end
    if pending then
        pending.col.y = pending.build(pending.col.frame, pending.col.y)
    end
end

--- Builds (once per bot) or returns the existing strategy window for `botName`.
local function GetOrCreateStrategyFrame(botName)
    local key = strlower(botName)
    local f = NS.botStrategyFrames[key]
    if f then return f end

    f = CreateFrame("Frame", "AltBotStrategy_" .. key, UIParent)
    f.botName = botName
    f.key = key
    f.group = (botName == "__group") or nil   -- the group window: same form, applied to all bots
    f.refreshers = {}
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    NS.RememberWindowPosition(f, "strategy", botName)
    f:SetScript("OnMouseDown", function(self) self:Raise() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0, 0, 0, 1)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", f, "TOP", 0, -16)
    f.title:SetText(f.group and "Group Strategy" or (botName .. "'s Strategy"))

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    --- The cached co?/nc? state of this bot for one section.
    f.State = function(self, isCombat)
        local st
        if self.group then
            st = self.groupCache or NS.GroupStrategyState(self)
        else
            st = NS.botStrategyState[self.key]
        end
        return st and st[isCombat and "combat" or "nonCombat"]
    end
    f.RefreshStrategies = function(self)
        -- the group window merges the bots' states once per repaint, not once per widget
        if self.group then self.groupCache = NS.GroupStrategyState(self) end
        for _, r in ipairs(self.refreshers) do r() end
        self.groupCache = nil
    end

    --- Builds the widget tree; needs the bot's class, so it waits for first open.
    --- Both of CleanBot's forms on one window: the Combat form (two columns) on
    --- top, the Non-Combat form (two columns) right under it (per explicit user
    --- direction).
    f.Build = function(self)
        if self.built then return end
        self.built = true
        local entry = NS.bots[self.key]
        self.class = entry and entry.class

        local colGap, margin = 14, 16
        local function MakeColumn(i, top)
            local c = CreateFrame("Frame", nil, self)
            c:SetSize(STRAT_COL_W, 1)
            c:SetPoint("TOPLEFT", self, "TOPLEFT", margin + (i - 1) * (STRAT_COL_W + colGap), -top)
            return c
        end

        -- Combat form
        local combatTop = 44
        local combatCols = {
            left  = { frame = MakeColumn(1, combatTop), y = 0 },
            right = { frame = MakeColumn(2, combatTop), y = 0 },
        }
        BuildStrategyGroups(self, NS.COMBAT_STRATEGIES, combatCols, true)
        local combatUsed = math.max(-combatCols.left.y, -combatCols.right.y)

        -- A divider line between the two forms (no "Combat"/"Non-Combat" captions,
        -- per explicit user direction), then the Non-Combat form below it.
        local sepY = combatTop + combatUsed + 6
        local sep = self:CreateTexture(nil, "ARTWORK")
        sep:SetPoint("TOPLEFT", self, "TOPLEFT", margin, -sepY)
        sep:SetSize(2 * STRAT_COL_W + colGap, 2)
        sep:SetTexture(1, 0.82, 0, 0.35)
        local ncTop = sepY + 14
        local ncCols = {
            left  = { frame = MakeColumn(1, ncTop), y = 0 },
            right = { frame = MakeColumn(2, ncTop), y = 0 },
        }
        BuildStrategyGroups(self, NS.NC_STRATEGIES, ncCols, false)
        local ncUsed = math.max(-ncCols.left.y, -ncCols.right.y)

        -- "Find": which tracking the bot keeps on - None / Herb / Ore (see NS.ApplyTracking). In the
        -- group window it sets it for every bot ("Mixed*" when they differ).
        local findTop = ncTop + ncUsed + 8
        local head = self:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        head:SetPoint("TOPLEFT", self, "TOPLEFT", margin, -findTop)
        head:SetText("Find")
        head:SetTextColor(1, 0.82, 0)
        local dd = CreateFrame("Frame", "AltBotFindDD_" .. self.key, self, "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", self, "TOPLEFT", margin - 16, -(findTop + 14))
        UIDropDownMenu_SetWidth(dd, STRAT_COL_W - 36)
        local function trackName(value)
            for _, o in ipairs(NS.TRACK_KINDS) do
                if o.value == value then return o.name end
            end
            return "None"
        end
        local function currentTrack()
            local kind
            for i, e in ipairs(NS.StrategyTargets(self)) do
                local k = NS.GetTrackKind(strlower(e.name))
                if i == 1 then kind = k elseif k ~= kind then return nil end
            end
            return kind or "none"
        end
        dd.Refresh = function()
            local kind = currentTrack()
            UIDropDownMenu_SetText(dd, kind and trackName(kind) or "Mixed*")
        end
        UIDropDownMenu_Initialize(dd, function()
            local cur = currentTrack()
            for _, o in ipairs(NS.TRACK_KINDS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = o.name
                info.checked = cur == o.value
                info.func = function()
                    for _, e in ipairs(NS.StrategyTargets(self)) do
                        NS.SetTrackKind(strlower(e.name), o.value)
                        NS.ApplyTracking(e)
                    end
                    dd.Refresh()
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        self.refreshers[#self.refreshers + 1] = dd.Refresh

        self:SetWidth(2 * margin + 2 * STRAT_COL_W + colGap)
        self:SetHeight(findTop + 14 + STRAT_DD_H + 14)
    end

    f:Hide()
    NS.botStrategyFrames[key] = f
    return f
end

--- Paints whatever's cached in NS.botStrategyState[key] into `botName`'s OWN
--- strategy frame (a no-op until the window has been opened once).
local function PaintStrategyFrame(botName)
    local f = NS.botStrategyFrames[strlower(botName)]
    if f and f.built then f:RefreshStrategies() end
    local g = NS.botStrategyFrames["__group"]
    if g and g.built and g:IsShown() then g:RefreshStrategies() end
end

--- Opens (fetching fresh combat/non-combat strategy) or closes `botName`'s
--- own strategy window: paint whatever's cached instantly, show, then send
--- this open's own "co ?"/"nc ?" whispers - no background poll to depend on.
NS.ToggleBotStrategy = function(botName)
    local f = GetOrCreateStrategyFrame(botName)
    if f:IsShown() then
        f:Hide()
        return
    end
    f:Build()
    f:RefreshStrategies()
    f:Show()
    NS.FetchStrategies(botName)
    SendBotCommand(botName, "ll ?")
end

--- The GROUP strategy window (master's name on the board): the same form as a bot's, every
--- change goes to all bots in the group. Opening reads every bot's strategies to show the
--- merged state.
NS.ToggleGroupStrategy = function()
    local f = GetOrCreateStrategyFrame("__group")
    if f:IsShown() then
        f:Hide()
        return
    end
    f:Build()
    f:RefreshStrategies()
    f:Show()
    for _, e in ipairs(NS.StrategyTargets(f)) do
        NS.FetchStrategies(e.name)
        SendBotCommand(e.name, "ll ?")
    end
end

-- Per-bot "co ?"/"nc ?" reply collection — a single-line reply (unlike the
-- multi-line "items"/"stats" streams), so no silence-timeout needed: parse
-- and render as soon as the "Strategies: ..." line arrives. A lost-reply
-- timeout still exists (strategyAwaitingSince/strategyTicker below) purely
-- to clear the manual-refresh pause a lost reply would otherwise hold
-- forever — see NS.BeginDetailFetch's own doc comment.
local strategyAwaiting = {}   -- lower(name) -> "combat" | "nonCombat"
NS.strategyAwaiting = strategyAwaiting   -- read by the chat classifier
local strategyAwaitingSince = {}   -- lower(name) -> elapsed seconds since FetchStrategy fired

--- Whispers "co ?" or "nc ?" to refresh one bot's currently-shown strategy
--- section. Exposed on NS (not local). Currently orphaned — the armory
--- window no longer has Combat/Non-Combat switch buttons that called this;
--- kept for the upcoming standalone per-bot strategy window.
NS.FetchStrategy = function(botName, section)
    local key = strlower(botName)
    -- ONE hold on the bot's polling per outstanding read: a second call while a
    -- read is still waiting only retargets it. (It used to Begin again and End
    -- only once - the counter never came back to zero and that bot's stats poll
    -- was skipped from then on: the board's tick indicator jumped over it and its
    -- column went stale or stayed "?".)
    if not strategyAwaiting[key] then NS.BeginDetailFetch(botName) end
    strategyAwaiting[key] = section
    strategyAwaitingSince[key] = 0
    SendBotCommand(botName, section == "combat" and "co ?" or "nc ?")
end

NS.strategyNext = {}   -- lower(name) -> section still to read after the current reply

--- Reads both sections for a bot, one after the other: "co ?", and when its
--- reply (or the timeout) is in, "nc ?".
NS.FetchStrategies = function(botName)
    NS.strategyNext[strlower(botName)] = "nonCombat"
    NS.FetchStrategy(botName, "combat")
end

local strategyWatcher = CreateFrame("Frame")
strategyWatcher:RegisterEvent("CHAT_MSG_WHISPER")
strategyWatcher:SetScript("OnEvent", function(self, event, msg, sender)
    local key = strlower(sender or "")
    -- "ll ?" answers "Loot strategy: <mode>" (the Loot Quality dropdown's value).
    local lootMode = NS.bots[key] and NS.CleanEscapes(msg):match("^Loot strategy:%s*(%a+)")
    if lootMode then
        NS.botStrategyState[key] = NS.botStrategyState[key] or {}
        NS.botStrategyState[key].lootStrategy = strlower(lootMode)
        PaintStrategyFrame((NS.bots[key] and NS.bots[key].name) or sender)
        return
    end
    local section = strategyAwaiting[key]
    if not section then return end
    if strsub(msg, 1, 12) ~= "Strategies: " then return end
    strategyAwaiting[key] = nil
    NS.EndDetailFetch(sender)
    local nextSection = NS.strategyNext[key]
    NS.strategyNext[key] = nil
    if nextSection then NS.FetchStrategy((NS.bots[key] and NS.bots[key].name) or sender, nextSection) end

    local map = section == "combat" and NS.STRATEGY_MAP or NS.NC_STRATEGY_MAP
    NS.botStrategyState[key] = NS.botStrategyState[key] or {}
    NS.botStrategyState[key][section] = ParseStrategyReply(msg, map)

    -- Repaint THIS bot's own independent strategy window, if it's open —
    -- the old shared-frame section-match guard (f.strategySection == section)
    -- no longer applies now that both combat and non-combat always render
    -- together in the same window (see PaintStrategyFrame).
    if NS.botStrategyFrames[key] then
        local entry = NS.bots[key]
        PaintStrategyFrame((entry and entry.name) or sender)
    end
end)

-- Fallback finalize: mod-playerbots gives no reliable delivery guarantee for
-- "co ?"/"nc ?" (same tradeoff as every other whisper command here — see the
-- file header), so a lost reply must still clear strategyAwaiting/the
-- manual-refresh pause it holds, or that bot would never be poll-eligible
-- again. Same STATS_TIMEOUT silence-timeout shape the items/quests/trainer
-- collectors use, just checked against a plain flag instead of a per-bot
-- collecting table.
local strategyTicker = CreateFrame("Frame")
strategyTicker:SetScript("OnUpdate", function(self, dt)
    local timedOut
    for key in pairs(strategyAwaiting) do
        strategyAwaitingSince[key] = (strategyAwaitingSince[key] or 0) + dt
        if strategyAwaitingSince[key] >= NS.STATS_TIMEOUT then
            timedOut = timedOut or {}
            timedOut[#timedOut + 1] = key
        end
    end
    -- Outside the traversal: starting the next read assigns strategyAwaiting[key] again.
    for _, key in ipairs(timedOut or {}) do
        strategyAwaiting[key] = nil
        strategyAwaitingSince[key] = nil
        NS.EndDetailFetch(key)
        local nextSection = NS.strategyNext[key]
        NS.strategyNext[key] = nil
        local entry = NS.bots[key]
        if nextSection and entry then NS.FetchStrategy(entry.name, nextSection) end
    end
end)

-- ============================================================
-- Reactive strategy window: bots confirm none of the co/nc commands, so a
-- change made from anywhere else - the action bar's group buttons (sent as
-- party/raid chat), AltBot's own mode switches, a command typed in chat or sent
-- by another addon - would leave an open strategy window showing stale state.
-- Every strategy-changing command we SEE going out (own whispers, own
-- party/raid chat) therefore schedules a fresh "co ?"/"nc ?" for the open
-- strategy windows concerned, a moment later so the server has applied it.
-- Queries ("co ?", "nc ?", "ll ?") never count - they'd retrigger themselves.
-- (Per explicit user direction: "иначе будет бардак, там так, тут так".)
-- ============================================================
NS.STRATEGY_REFETCH_DELAY = 1.2   -- seconds after the last change before re-reading
NS.strategyRefetchAt = {}         -- lower(bot) -> GetTime() when its window is due a re-read

-- The plain movement commands (the action bar's Follow / Stay buttons send
-- "follow" / "stay" to the group) change the non-combat movement strategy too;
-- the field they set in the Movement dropdown, where we know it.
NS.MOVEMENT_WORD_FIELD = { follow = "mFollow", stay = "mStay", guard = "mGuard", flee = false }

--- field -> list of the fields it is mutually exclusive with (its dropdown's
--- members), per section; built from the strategy tables on first use.
NS.strategySiblings = { combat = nil, nonCombat = nil }
NS.BuildSiblings = function(groups)
    local siblings = {}
    local function addGroup(list)
        local fields = {}
        for _, o in ipairs(list) do fields[#fields + 1] = o.field end
        for _, f in ipairs(fields) do siblings[f] = fields end
    end
    local function scan(entries)
        for _, e in ipairs(entries or {}) do
            if e.type == "dropdown" and e.strategies then addGroup(e.strategies) end
        end
    end
    for _, grp in ipairs(groups) do
        if (grp.type == "dropdown" or grp.type == "roleDropdown") and grp.strategies then
            addGroup(grp.strategies)
        end
        scan(grp.strategies)
        for _, sg in ipairs(grp.subGroups or {}) do scan(sg.strategies) end
    end
    return siblings
end

--- Brings the cached strategy state (and so every open strategy window) in line
--- with a "co ..."/"nc ..." command seen in chat: "+token" turns a strategy on
--- (and its dropdown siblings off), "-token" turns it off, comma-separated like
--- the server reads them. Only for bot `key`, or every tracked bot when nil.
--- The re-read a moment later (NS.NotifyStrategyChange) confirms it.
NS.ApplyStrategyCommand = function(msg, key)
    local section, list = msg:match("^(%a%a)%s+(.+)$")
    if section ~= "co" and section ~= "nc" then return end
    local isCombat = section == "co"
    local map = isCombat and NS.STRATEGY_MAP or NS.NC_STRATEGY_MAP
    local secKey = isCombat and "combat" or "nonCombat"
    local siblings = NS.strategySiblings[secKey]
        or NS.BuildSiblings(isCombat and NS.COMBAT_STRATEGIES or NS.NC_STRATEGIES)
    NS.strategySiblings[secKey] = siblings

    local changes = {}   -- { field, value } in order
    for token in list:gmatch("[^,]+") do
        local sign, name = token:match("^%s*([%+%-])%s*(.-)%s*$")
        local field = sign and map[name]
        if field then changes[#changes + 1] = { field, sign == "+" } end
    end
    if #changes == 0 then return end

    local function apply(k)
        for _, c in ipairs(changes) do
            if c[2] and siblings[c[1]] then
                for _, other in ipairs(siblings[c[1]]) do
                    NS.SetStrategyField(k, isCombat, other, other == c[1])
                end
            else
                NS.SetStrategyField(k, isCombat, c[1], c[2])
            end
        end
    end
    if key then apply(key) else for k in pairs(NS.bots) do apply(k) end end
    for k, f in pairs(NS.botStrategyFrames) do
        if f.built and (not key or k == key or f.group) then f:RefreshStrategies() end
    end
end

NS.IsStrategyCommand = function(msg)
    if not msg or msg:match("%?%s*$") then return false end
    return msg:match("^co%s") ~= nil or msg:match("^nc%s") ~= nil
        or msg:match("^ll%s") ~= nil or msg == "reset botAI"
        or NS.MOVEMENT_WORD_FIELD[msg] ~= nil
end

--- Shows a plain movement command in the cached state at once (the re-read a
--- moment later confirms it): Follow/Stay/Guard become the active Movement
--- entry for bot `key`, or for every tracked bot when key is nil.
NS.ApplyMovementWord = function(word, key)
    local field = NS.MOVEMENT_WORD_FIELD[word]
    if not field then return end
    local function apply(k)
        for _, m in ipairs(NS.MOVEMENT_STRATEGIES) do
            NS.SetStrategyField(k, false, m.field, m.field == field)
        end
    end
    if key then
        apply(key)
    else
        for k in pairs(NS.bots) do apply(k) end
    end
    for k, f in pairs(NS.botStrategyFrames) do
        if f.built and (not key or k == key or f.group) then f:RefreshStrategies() end
    end
end

--- A strategy change was just sent to bot `key` (lowercase), or to every bot
--- when nil: re-read it as soon as things settle - only for open windows.
NS.NotifyStrategyChange = function(key)
    for k, f in pairs(NS.botStrategyFrames) do
        if (not key or k == key) and f:IsShown() and f.built and not f.group then
            NS.strategyRefetchAt[k] = GetTime() + NS.STRATEGY_REFETCH_DELAY
        end
    end
    -- an open GROUP window shows every bot: re-read the bot(s) concerned
    local g = NS.botStrategyFrames["__group"]
    if g and g:IsShown() and g.built then
        for k in pairs(NS.bots) do
            if not key or k == key then NS.strategyRefetchAt[k] = GetTime() + NS.STRATEGY_REFETCH_DELAY end
        end
    end
end

NS.strategyChangeWatcher = CreateFrame("Frame")
-- Chat is what matters, not the action bar: the bar's buttons just send a plain
-- command ("stay", "follow", "co +aggressive,-passive") as party/raid chat, so
-- anything typed by hand in /p, /raid, /s, /y or /g is caught the same way.
for _, ev in ipairs({ "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
                      "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_SAY", "CHAT_MSG_YELL",
                      "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER" }) do
    NS.strategyChangeWatcher:RegisterEvent(ev)
end
NS.strategyChangeWatcher:SetScript("OnEvent", function(self, event, msg, who)
    if not NS.IsStrategyCommand(msg) then return end
    -- Shows that a strategy-changing command was seen (shown by the "chat co/nc" setting).
    Print(string.format("|cff00ff00[Strategy]|r caught: %s  <- %s%s", msg, (event:gsub("^CHAT_MSG_", "")),
        event == "CHAT_MSG_WHISPER_INFORM" and (" " .. tostring(who)) or ""), "strategies")
    if event == "CHAT_MSG_WHISPER_INFORM" then
        local key = strlower(who or "")
        if NS.bots[key] then
            NS.ApplyMovementWord(msg, key)
            NS.ApplyStrategyCommand(msg, key)
            NS.NotifyStrategyChange(key)
        end
    else
        -- group / say / guild chat: only what WE said
        local name = who and who:match("^([^%-]+)") or who
        if name == UnitName("player") then
            NS.ApplyMovementWord(msg, nil)
            NS.ApplyStrategyCommand(msg, nil)
            NS.NotifyStrategyChange(nil)
        end
    end
end)

NS.strategyRefetchTicker = CreateFrame("Frame")
NS.strategyRefetchTicker:SetScript("OnUpdate", function(self, dt)
    if not next(NS.strategyRefetchAt) then return end
    local now = GetTime()
    local due
    for k, at in pairs(NS.strategyRefetchAt) do
        if now >= at then
            due = due or {}
            due[#due + 1] = k
        end
    end
    if not due then return end
    for _, k in ipairs(due) do   -- (outside the traversal above: FetchStrategy touches other tables)
        NS.strategyRefetchAt[k] = nil
        local f = NS.botStrategyFrames[k]
        local g = NS.botStrategyFrames["__group"]
        local entry = NS.bots[k]
        if entry and ((f and f:IsShown()) or (g and g:IsShown())) then
            NS.FetchStrategies(entry.name)
        end
    end
end)

--- Opens (fetching fresh equipment) or closes `botName`'s OWN armory window.
--- Mirrors NS.ToggleBotBags — each bot has its own independent frame now, so
--- this is a plain show/hide-if-already-shown, no more "rebind a shared
--- frame to a different bot" dance the old single detail window needed.
NS.ToggleBotArmory = function(botName)
    local f = GetOrCreateArmoryFrame(botName)
    if f.closing then
        NS.RestoreArmoryVisible(f)   -- reopened during the fictive close: just show it again
        return
    end
    if f:IsShown() then
        NS.CloseArmory(f)
        return
    end

    f.title:SetText(botName)
    NS.PaintArmoryHeader(f)
    -- Paint instantly from whatever's already cached (this bot's armory
    -- window opened earlier this session) — same "instant repaint from
    -- last-known, then update from the fresh reply" pattern the bags window
    -- uses — before kicking off a fresh fetch below. Per explicit user
    -- direction: "держать последний эквип для всех ботов в кэше, сразу его
    -- показывать".
    f.unit = FindBotUnit(botName)   -- for tooltips only; no network request fired here
    f.modelUnit = nil   -- (modelMode stays: the model loaded earlier this session is kept)
    NS.UpdateArmoryModel(f)
    PaintEquipSlotsFromCache(f, strlower(botName))
    f:Show()

    -- No background poller fills the equip cache any more (removed) — this
    -- window fetches its own fresh equipment every time it opens, rather
    -- than depending on any other window being open or a poll having run.
    NS.RefreshBotEquipBackground(botName)
end

-- ============================================================
-- Armory model warm-up. A bot's real 3D model can only be loaded while the bot is in
-- view AND its armory window is shown (see NS.UpdateArmoryModel), and it's then kept
-- until /reload. So the first time a bot is seen next to the master in a session -
-- after a summon (switch to Quest mode, bag unloading, a revive) - its window is
-- shown for a moment, off-screen and invisible, just long enough for the model to
-- load. Once per bot per session.
-- ============================================================
NS.armoryWarmed = {}   -- lower(name) -> true once its model has been warmed this session

NS.WarmArmoryModel = function(botName)
    local key = strlower(botName)
    if NS.armoryWarmed[key] or not NS.bots[key] then return end
    local unit = FindBotUnit(botName)
    if not (unit and UnitExists(unit) and UnitIsVisible(unit)) then return end   -- not in view yet: try again later
    NS.armoryWarmed[key] = true

    local f = GetOrCreateArmoryFrame(botName)
    if f:IsShown() then
        NS.UpdateArmoryModel(f)   -- already open: it just loads the model
        return
    end
    local point, rel, relPoint, x, y = f:GetPoint()
    f:SetAlpha(0)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -6000, 0)
    f:Show()
    NS.UpdateArmoryModel(f)
    NS.After(1.5, function()
        f:Hide()
        f:SetAlpha(1)
        f:ClearAllPoints()
        f:SetPoint(point or "CENTER", rel or UIParent, relPoint or "CENTER", x or -200, y or 0)
    end)
end

--- Warm every tracked bot that's in view right now (after a group summon).
NS.WarmAllArmoryModels = function()
    for _, key in ipairs(NS.rosterOrder) do
        local entry = NS.bots[key]
        if entry then NS.WarmArmoryModel(entry.name) end
    end
end

-- ============================================================
-- Quest log window - a fully independent, per-bot frame (same shell as the bags/strategy windows:
-- own frame registry, opaque backdrop, raise-on-click, paint-before-show, fetches its own
-- "quests all" on open). A scrolling table, per explicit user direction:
--   * the unfinished quests GROUPED BY ZONE, then the COMPLETED ones last (quest id -> zone id is NS.QUEST_ZONE, the Russian
--     titles NS.QUEST_TITLE_RU, both generated from the QuestChromeCraft addon's data and embedded here;
--     zone names are NS.ZONE_NAMES);
--   * columns: quest id (right-aligned) | [number of bots in the raid, and the master, that have this quest] | quest
--     link followed by its Russian title.
-- The bot counts come from every tracked bot's own quest list, so opening the window also refreshes
-- those lists; all lists are saved (AltBot_SavedVars.questCache) and show at once.
-- ============================================================
local QUEST_ROW_H = 20
local QUEST_FRAME_W = 480
local QUEST_ID_W = 46      -- left column: quest id, right-aligned
local questAwaiting = {}   -- lower(name) -> { quests = {}, status = "I", timer = 0 }
NS.questAwaiting = questAwaiting   -- read by the chat classifier
NS.QUEST_CNT_W = 34        -- the "[N]" column

NS.botQuestFrames = NS.botQuestFrames or {}   -- lower(name) -> frame, created lazily on first open
NS.botQuestState = NS.botQuestState or {}     -- lower(name) -> array of {id, status, name, link}, last known list

-- BEGIN GENERATED QUESTZONE (tools/questzone_generate.py rewrites everything up to END)
NS.QUEST_ZONE = {
    [1]=151,[2]=331,[5]=10,[6]=12,[7]=12,[8]=85,[9]=40,[10]=440,[11]=12,[12]=40,[13]=40,[14]=40,[15]=12,[16]=12,
    [17]=1337,[18]=12,[19]=44,[20]=44,[21]=12,[22]=40,[23]=331,[24]=331,[31]=331,[32]=440,[33]=12,[34]=44,[35]=12,
    [36]=40,[37]=12,[38]=40,[39]=12,[40]=12,[45]=12,[46]=12,[47]=12,[48]=40,[49]=40,[50]=40,[51]=40,[52]=12,[53]=40,
    [54]=12,[55]=10,[56]=10,[57]=10,[58]=10,[59]=12,[60]=12,[61]=12,[63]=12,[64]=40,[65]=40,[66]=10,[67]=10,[68]=10,
    [69]=10,[70]=10,[71]=12,[72]=10,[74]=10,[75]=10,[76]=12,[77]=47,[78]=10,[79]=10,[80]=10,[81]=1637,[82]=440,
    [83]=12,[84]=12,[85]=12,[86]=12,[87]=12,[88]=12,[89]=44,[90]=10,[91]=44,[92]=44,[93]=10,[94]=44,[96]=10,[97]=10,
    [98]=10,[100]=130,[101]=10,[102]=40,[103]=40,[104]=40,[105]=28,[106]=12,[107]=12,[109]=12,[110]=440,[111]=12,
    [112]=12,[113]=440,[114]=12,[115]=44,[116]=44,[117]=40,[118]=44,[119]=44,[120]=44,[121]=44,[122]=44,[123]=12,
    [124]=44,[125]=44,[126]=44,[127]=44,[128]=44,[129]=44,[130]=44,[131]=44,[132]=40,[133]=10,[134]=10,[135]=40,
    [136]=40,[138]=40,[139]=40,[140]=40,[141]=40,[142]=40,[143]=44,[144]=44,[145]=44,[146]=44,[147]=12,[148]=10,
    [149]=10,[150]=44,[151]=40,[152]=40,[153]=40,[154]=10,[155]=40,[156]=10,[157]=10,[158]=10,[159]=10,[160]=10,
    [161]=38,[162]=440,[163]=10,[164]=10,[165]=10,[166]=1581,[167]=1581,[168]=1581,[169]=44,[172]=1,[173]=10,[174]=10,
    [175]=10,[176]=12,[177]=10,[178]=44,[179]=1,[180]=44,[181]=10,[182]=1,[183]=1,[184]=40,[185]=33,[186]=33,[187]=33,
    [188]=33,[189]=33,[190]=33,[191]=33,[192]=33,[193]=33,[194]=33,[195]=33,[196]=33,[197]=33,[198]=33,[199]=38,
    [200]=33,[201]=33,[202]=33,[203]=33,[204]=33,[205]=33,[206]=33,[207]=33,[208]=33,[209]=33,[210]=33,[211]=28,
    [212]=1519,[213]=33,[214]=1581,[215]=33,[216]=331,[217]=38,[218]=1,[220]=44,[221]=10,[222]=10,[223]=10,[224]=38,
    [225]=10,[226]=10,[227]=10,[228]=10,[229]=10,[230]=10,[231]=10,[232]=1497,[233]=1,[234]=1,[235]=1637,[236]=4197,
    [237]=38,[238]=1497,[239]=12,[240]=10,[243]=440,[244]=44,[245]=10,[246]=44,[247]=331,[248]=44,[249]=44,[250]=38,
    [251]=10,[252]=10,[253]=10,[254]=10,[255]=38,[256]=38,[257]=38,[258]=38,[261]=405,[262]=10,[263]=38,[264]=1638,
    [265]=10,[266]=10,[267]=38,[268]=10,[269]=10,[270]=10,[272]=38,[273]=38,[274]=38,[275]=11,[276]=11,[277]=11,
    [278]=38,[279]=11,[280]=38,[281]=11,[282]=1,[283]=38,[284]=11,[285]=11,[286]=11,[287]=1,[288]=11,[289]=11,
    [290]=11,[291]=1,[292]=11,[293]=11,[294]=11,[295]=11,[296]=11,[297]=38,[298]=38,[299]=11,[301]=38,[302]=38,
    [303]=11,[304]=11,[305]=11,[306]=11,[307]=38,[308]=1,[309]=38,[310]=1,[311]=1,[312]=1,[313]=1,[314]=1,[315]=1,
    [317]=1,[318]=1,[319]=1,[320]=1,[321]=10,[322]=10,[323]=10,[324]=10,[325]=10,[328]=33,[329]=33,[330]=33,[331]=33,
    [332]=1519,[333]=1519,[334]=1519,[335]=1519,[336]=1519,[337]=10,[338]=33,[339]=33,[340]=33,[341]=33,[342]=33,
    [343]=1519,[344]=1519,[345]=1519,[346]=1519,[347]=1519,[348]=33,[349]=33,[350]=1519,[351]=440,[353]=1519,[354]=85,
    [355]=85,[356]=85,[357]=1497,[358]=85,[359]=85,[360]=85,[361]=85,[362]=85,[363]=85,[364]=85,[365]=85,[366]=85,
    [367]=85,[368]=85,[369]=85,[370]=85,[371]=85,[372]=85,[373]=1519,[374]=85,[375]=85,[376]=85,[377]=717,[378]=717,
    [379]=440,[380]=85,[381]=85,[382]=85,[384]=85,[385]=38,[386]=717,[387]=717,[388]=717,[389]=1519,[391]=717,
    [392]=1519,[393]=1519,[394]=1519,[395]=1519,[396]=1519,[397]=1519,[398]=85,[399]=1519,[400]=1,[401]=10,[402]=10,
    [403]=1,[404]=85,[405]=85,[407]=85,[408]=85,[409]=85,[410]=85,[411]=85,[412]=1,[413]=1,[414]=1,[415]=1,[416]=38,
    [417]=1,[418]=38,[419]=1,[420]=1,[421]=130,[422]=130,[423]=130,[424]=130,[425]=130,[426]=85,[427]=85,[428]=130,
    [429]=130,[430]=130,[431]=85,[432]=1,[433]=1,[434]=1519,[435]=130,[436]=38,[437]=130,[438]=130,[439]=130,
    [440]=130,[441]=130,[442]=130,[443]=130,[444]=130,[445]=85,[446]=130,[447]=130,[448]=130,[449]=130,[450]=130,
    [451]=130,[452]=130,[453]=10,[454]=38,[455]=11,[456]=141,[457]=141,[458]=141,[459]=141,[460]=130,[461]=130,
    [463]=11,[464]=11,[465]=11,[466]=1,[467]=1,[468]=11,[469]=11,[470]=11,[471]=11,[472]=11,[473]=11,[474]=11,
    [475]=141,[476]=141,[477]=130,[478]=130,[479]=130,[480]=130,[481]=130,[482]=130,[483]=141,[484]=11,[485]=47,
    [486]=141,[487]=141,[488]=141,[489]=141,[491]=130,[492]=85,[493]=130,[494]=267,[495]=1497,[496]=267,[498]=267,
    [499]=267,[500]=36,[501]=267,[502]=267,[503]=267,[504]=36,[505]=36,[506]=267,[507]=267,[508]=267,[509]=267,
    [510]=36,[511]=36,[512]=36,[513]=267,[514]=36,[515]=267,[516]=130,[517]=267,[518]=267,[519]=267,[520]=267,
    [521]=267,[522]=36,[523]=36,[524]=267,[525]=36,[526]=10,[527]=267,[528]=267,[529]=267,[530]=130,[531]=38,
    [532]=267,[533]=267,[535]=36,[536]=267,[537]=36,[538]=1519,[539]=267,[540]=1519,[541]=267,[542]=1519,[543]=1519,
    [544]=267,[545]=267,[546]=267,[547]=267,[549]=267,[550]=267,[551]=36,[552]=267,[553]=267,[554]=36,[555]=267,
    [556]=267,[558]=267,[559]=267,[560]=267,[561]=267,[562]=267,[563]=267,[564]=267,[565]=267,[566]=267,[567]=267,
    [568]=33,[569]=33,[570]=33,[571]=33,[572]=33,[573]=33,[574]=33,[575]=33,[576]=33,[577]=33,[578]=33,[579]=1519,
    [580]=33,[581]=33,[582]=33,[583]=33,[584]=33,[585]=33,[586]=33,[587]=33,[588]=33,[589]=33,[590]=85,[591]=33,
    [592]=33,[593]=33,[594]=33,[595]=33,[596]=33,[597]=33,[598]=33,[599]=33,[600]=33,[601]=33,[602]=33,[603]=33,
    [604]=33,[605]=33,[606]=33,[607]=33,[608]=33,[609]=33,[610]=33,[611]=33,[613]=33,[614]=33,[615]=33,[616]=33,
    [617]=33,[618]=33,[619]=33,[620]=33,[621]=33,[622]=33,[623]=33,[624]=33,[625]=33,[626]=33,[627]=33,[628]=33,
    [629]=33,[630]=33,[631]=11,[632]=11,[633]=11,[634]=11,[635]=45,[636]=45,[637]=1537,[638]=33,[639]=45,[640]=45,
    [641]=45,[642]=45,[643]=45,[644]=45,[645]=45,[646]=45,[647]=11,[648]=440,[649]=1637,[650]=1637,[651]=45,[652]=45,
    [653]=45,[654]=440,[655]=45,[656]=45,[657]=267,[658]=267,[659]=267,[660]=267,[661]=267,[662]=45,[663]=45,[664]=45,
    [665]=45,[666]=45,[667]=45,[668]=45,[669]=45,[670]=45,[671]=45,[672]=45,[673]=45,[674]=45,[675]=45,[676]=267,
    [677]=45,[678]=45,[679]=45,[680]=45,[681]=45,[682]=45,[683]=1537,[684]=45,[685]=45,[686]=1537,[687]=45,[688]=45,
    [689]=1537,[690]=1519,[691]=45,[692]=3,[693]=45,[694]=45,[695]=45,[696]=45,[697]=45,[698]=8,[699]=8,[700]=1537,
    [701]=45,[702]=45,[703]=3,[704]=1337,[705]=3,[706]=3,[707]=1537,[708]=3,[709]=1337,[710]=3,[711]=3,[712]=3,
    [713]=3,[714]=3,[715]=3,[716]=3,[717]=3,[718]=3,[719]=3,[720]=3,[721]=1337,[722]=1337,[723]=3,[724]=3,[725]=3,
    [726]=3,[727]=3,[728]=3,[729]=148,[730]=1657,[731]=148,[732]=3,[733]=3,[734]=3,[735]=3,[736]=1497,[737]=3,[738]=3,
    [739]=3,[741]=148,[742]=1638,[743]=215,[744]=1638,[745]=215,[746]=215,[747]=215,[748]=215,[749]=215,[750]=215,
    [751]=215,[752]=215,[753]=215,[754]=215,[755]=215,[756]=215,[757]=215,[758]=215,[759]=215,[760]=215,[761]=215,
    [762]=3,[763]=215,[764]=215,[765]=215,[766]=215,[767]=215,[768]=1638,[769]=1638,[770]=215,[771]=215,[772]=215,
    [773]=215,[775]=215,[776]=215,[777]=3,[778]=3,[779]=3,[780]=215,[781]=215,[782]=3,[783]=12,[784]=14,[785]=14,
    [786]=14,[787]=14,[788]=14,[789]=14,[790]=14,[791]=14,[792]=14,[793]=3,[794]=14,[795]=3,[804]=14,[805]=14,
    [806]=14,[808]=14,[809]=14,[812]=14,[813]=14,[815]=14,[816]=14,[817]=14,[818]=14,[819]=17,[821]=17,[822]=17,
    [823]=14,[824]=331,[825]=14,[826]=14,[827]=14,[828]=14,[829]=14,[830]=14,[831]=14,[832]=14,[833]=215,[834]=14,
    [835]=14,[836]=47,[837]=14,[838]=28,[840]=14,[841]=440,[842]=14,[843]=17,[844]=17,[845]=17,[846]=17,[847]=45,
    [848]=17,[849]=17,[850]=17,[851]=17,[852]=17,[853]=17,[854]=215,[855]=17,[857]=17,[858]=17,[860]=17,[862]=215,
    [863]=17,[864]=1497,[866]=17,[867]=17,[868]=17,[869]=17,[870]=17,[871]=17,[872]=17,[873]=17,[874]=17,[875]=17,
    [876]=17,[877]=17,[878]=17,[879]=17,[880]=17,[881]=17,[882]=17,[883]=17,[884]=17,[885]=17,[886]=17,[887]=17,
    [888]=17,[889]=17,[890]=17,[891]=17,[892]=17,[893]=17,[894]=17,[895]=17,[896]=17,[897]=17,[898]=17,[899]=17,
    [900]=17,[901]=17,[902]=17,[903]=17,[905]=17,[906]=17,[907]=17,[908]=331,[911]=331,[913]=17,[915]=718,[916]=141,
    [917]=141,[918]=141,[919]=141,[920]=141,[921]=141,[922]=141,[923]=141,[925]=14,[926]=14,[927]=141,[928]=141,
    [929]=141,[930]=141,[931]=141,[932]=141,[933]=141,[934]=141,[935]=141,[936]=1637,[937]=141,[938]=141,[939]=361,
    [940]=141,[941]=141,[942]=148,[943]=148,[944]=148,[945]=148,[947]=148,[948]=148,[949]=148,[950]=148,[951]=148,
    [952]=1657,[953]=148,[954]=148,[955]=148,[956]=148,[957]=148,[958]=148,[959]=718,[960]=148,[961]=148,[962]=718,
    [963]=148,[964]=28,[965]=148,[966]=148,[967]=148,[968]=148,[969]=618,[970]=148,[972]=719,[973]=148,[974]=490,
    [975]=618,[976]=331,[977]=618,[978]=702,[979]=702,[980]=490,[981]=148,[982]=148,[983]=148,[984]=148,[985]=148,
    [986]=148,[990]=331,[991]=331,[992]=440,[993]=148,[994]=148,[995]=148,[996]=361,[997]=141,[998]=361,[999]=718,
    [1000]=1638,[1001]=148,[1002]=148,[1003]=148,[1004]=1497,[1005]=236,[1006]=236,[1007]=331,[1008]=331,[1009]=331,
    [1010]=331,[1011]=331,[1012]=331,[1013]=209,[1014]=209,[1015]=1519,[1016]=331,[1017]=331,[1018]=1637,[1019]=1537,
    [1020]=331,[1021]=331,[1022]=331,[1023]=331,[1024]=331,[1025]=331,[1026]=331,[1027]=331,[1028]=331,[1029]=331,
    [1030]=331,[1031]=331,[1032]=331,[1033]=331,[1034]=331,[1035]=331,[1036]=33,[1037]=331,[1038]=331,[1039]=331,
    [1040]=331,[1041]=331,[1042]=331,[1043]=331,[1044]=331,[1045]=331,[1046]=331,[1047]=1657,[1048]=796,[1049]=796,
    [1050]=796,[1051]=796,[1052]=405,[1053]=796,[1054]=331,[1055]=331,[1056]=331,[1057]=406,[1058]=406,[1059]=406,
    [1060]=17,[1061]=406,[1062]=406,[1063]=406,[1064]=1638,[1065]=1638,[1066]=1638,[1067]=1638,[1068]=406,[1069]=17,
    [1070]=331,[1071]=406,[1072]=406,[1073]=406,[1074]=406,[1075]=406,[1076]=406,[1077]=406,[1078]=406,[1079]=406,
    [1080]=406,[1081]=406,[1082]=406,[1083]=406,[1084]=406,[1085]=331,[1086]=1638,[1087]=406,[1088]=406,[1089]=406,
    [1090]=406,[1091]=406,[1092]=406,[1093]=406,[1094]=406,[1095]=406,[1096]=406,[1097]=1519,[1098]=209,[1099]=400,
    [1100]=400,[1101]=491,[1103]=491,[1104]=400,[1105]=400,[1106]=400,[1107]=400,[1108]=400,[1109]=491,[1110]=400,
    [1111]=400,[1112]=400,[1113]=796,[1114]=400,[1115]=400,[1116]=8,[1117]=400,[1118]=400,[1119]=400,[1120]=400,
    [1121]=400,[1122]=400,[1123]=1638,[1124]=493,[1125]=1377,[1126]=1377,[1127]=33,[1130]=1638,[1131]=1638,[1132]=11,
    [1133]=148,[1134]=331,[1135]=15,[1136]=1638,[1137]=400,[1138]=148,[1139]=1337,[1140]=148,[1141]=148,[1142]=491,
    [1143]=148,[1144]=491,[1145]=17,[1146]=1637,[1147]=400,[1148]=400,[1149]=400,[1150]=400,[1151]=400,[1152]=400,
    [1153]=17,[1154]=400,[1159]=400,[1160]=796,[1164]=1497,[1166]=15,[1167]=148,[1168]=15,[1169]=15,[1170]=15,
    [1171]=15,[1172]=15,[1173]=15,[1175]=400,[1176]=400,[1177]=15,[1178]=400,[1179]=400,[1180]=400,[1181]=400,
    [1182]=400,[1183]=400,[1184]=400,[1185]=493,[1186]=400,[1187]=400,[1188]=400,[1189]=400,[1190]=400,[1191]=400,
    [1192]=400,[1193]=2557,[1194]=400,[1195]=1638,[1196]=1638,[1197]=1638,[1198]=719,[1199]=719,[1200]=719,[1201]=15,
    [1202]=15,[1203]=15,[1204]=15,[1205]=15,[1206]=15,[1218]=15,[1219]=15,[1220]=15,[1221]=491,[1222]=15,[1238]=15,
    [1239]=15,[1240]=15,[1241]=1519,[1242]=1519,[1243]=1519,[1244]=1519,[1245]=1519,[1246]=1519,[1247]=1519,
    [1248]=1519,[1249]=1519,[1250]=1519,[1251]=15,[1252]=15,[1253]=15,[1258]=15,[1259]=15,[1260]=15,[1261]=15,
    [1262]=15,[1263]=15,[1264]=1519,[1265]=1519,[1266]=1519,[1267]=1519,[1268]=15,[1269]=15,[1270]=15,[1271]=15,
    [1272]=15,[1273]=15,[1274]=1519,[1275]=719,[1276]=15,[1281]=15,[1282]=15,[1284]=15,[1285]=15,[1286]=15,[1287]=15,
    [1288]=15,[1301]=1519,[1302]=11,[1318]=2557,[1319]=15,[1320]=15,[1321]=15,[1322]=15,[1323]=15,[1324]=1519,
    [1338]=38,[1339]=38,[1358]=1497,[1359]=1497,[1360]=1337,[1361]=405,[1362]=405,[1363]=1519,[1364]=1519,[1365]=405,
    [1366]=405,[1367]=405,[1368]=405,[1369]=405,[1370]=405,[1371]=405,[1372]=10,[1373]=405,[1374]=405,[1375]=405,
    [1380]=405,[1381]=405,[1382]=405,[1383]=10,[1384]=405,[1385]=405,[1386]=405,[1387]=405,[1388]=10,[1389]=8,
    [1391]=10,[1392]=8,[1393]=8,[1394]=400,[1395]=10,[1396]=8,[1398]=8,[1418]=8,[1419]=3,[1420]=3,[1421]=8,[1422]=8,
    [1423]=8,[1424]=8,[1425]=8,[1426]=8,[1427]=8,[1428]=8,[1429]=8,[1430]=8,[1431]=1637,[1432]=1637,[1433]=1637,
    [1434]=1637,[1435]=1637,[1436]=1637,[1437]=405,[1438]=405,[1439]=405,[1442]=405,[1444]=47,[1445]=1477,[1446]=1477,
    [1447]=1519,[1448]=1519,[1449]=1519,[1450]=47,[1451]=47,[1452]=47,[1453]=1537,[1454]=405,[1455]=405,[1456]=405,
    [1457]=405,[1458]=405,[1464]=405,[1465]=405,[1466]=405,[1468]=405,[1474]=47,[1476]=1477,[1479]=1519,[1480]=405,
    [1481]=405,[1482]=405,[1483]=17,[1485]=405,[1486]=718,[1487]=718,[1488]=405,[1489]=718,[1490]=718,[1491]=718,
    [1499]=17,[1513]=718,[1559]=361,[1655]=440,[1689]=215,[1690]=440,[1706]=440,[1781]=440,[1899]=440,[2000]=331,
    [2038]=38,[2039]=1537,[2040]=1581,[2041]=1537,[2078]=148,[2098]=148,[2118]=148,[2138]=148,[2139]=148,[2158]=12,
    [2159]=141,[2160]=1,[2178]=14,[2198]=1337,[2199]=1337,[2200]=1337,[2201]=1337,[2202]=1337,[2203]=3,[2239]=1337,
    [2242]=1337,[2260]=3,[2278]=1337,[2279]=1337,[2282]=1337,[2283]=1337,[2300]=1337,[2318]=1337,[2338]=1337,
    [2339]=1337,[2340]=1337,[2341]=1337,[2360]=1337,[2383]=1337,[2398]=1337,[2399]=141,[2418]=1337,[2438]=141,
    [2439]=1537,[2458]=1638,[2480]=141,[2498]=141,[2499]=141,[2500]=38,[2501]=38,[2518]=1657,[2519]=1657,[2520]=1657,
    [2521]=4,[2522]=4,[2523]=361,[2541]=141,[2561]=141,[2581]=4,[2582]=4,[2583]=4,[2584]=4,[2585]=4,[2586]=4,[2601]=4,
    [2602]=4,[2603]=4,[2604]=4,[2605]=440,[2609]=440,[2621]=4,[2622]=8,[2623]=8,[2641]=440,[2661]=440,[2662]=440,
    [2681]=4,[2701]=4,[2702]=4,[2721]=4,[2741]=440,[2742]=47,[2743]=4,[2744]=4,[2745]=1519,[2746]=1519,[2747]=440,
    [2748]=440,[2749]=440,[2765]=440,[2766]=357,[2767]=357,[2768]=1176,[2769]=400,[2773]=1176,[2781]=440,[2782]=47,
    [2783]=4,[2784]=4,[2801]=4,[2821]=357,[2822]=357,[2841]=721,[2842]=721,[2843]=721,[2844]=357,[2845]=357,
    [2860]=1176,[2861]=1176,[2862]=357,[2863]=357,[2864]=1176,[2865]=1176,[2866]=357,[2867]=357,[2869]=357,[2870]=357,
    [2871]=357,[2872]=440,[2873]=440,[2874]=440,[2875]=440,[2876]=440,[2877]=47,[2878]=357,[2879]=357,[2880]=47,
    [2882]=47,[2902]=357,[2903]=357,[2904]=721,[2922]=721,[2923]=721,[2924]=721,[2925]=721,[2926]=721,[2927]=721,
    [2928]=721,[2929]=721,[2930]=721,[2931]=721,[2932]=47,[2933]=47,[2934]=47,[2935]=47,[2936]=1176,[2937]=47,
    [2938]=47,[2939]=357,[2940]=357,[2941]=357,[2942]=357,[2943]=357,[2944]=357,[2945]=721,[2946]=1537,[2947]=721,
    [2948]=1537,[2949]=721,[2950]=1637,[2951]=721,[2952]=721,[2953]=721,[2954]=440,[2962]=721,[2963]=1537,[2964]=1537,
    [2965]=1638,[2966]=1638,[2967]=1638,[2968]=1638,[2969]=357,[2970]=357,[2972]=357,[2973]=357,[2974]=357,[2975]=357,
    [2976]=357,[2977]=1537,[2978]=357,[2979]=357,[2980]=357,[2981]=1637,[2986]=357,[2987]=357,[2988]=47,[2989]=47,
    [2990]=47,[2991]=1176,[2992]=47,[2993]=47,[2994]=47,[3001]=1497,[3002]=357,[3022]=440,[3042]=1176,[3062]=357,
    [3120]=357,[3121]=357,[3122]=357,[3123]=357,[3124]=357,[3125]=357,[3126]=357,[3127]=357,[3128]=357,[3129]=357,
    [3130]=357,[3141]=16,[3161]=440,[3181]=51,[3182]=38,[3201]=1537,[3221]=130,[3261]=17,[3281]=17,[3321]=17,
    [3341]=722,[3361]=1,[3362]=440,[3363]=361,[3364]=1,[3365]=1,[3366]=718,[3367]=51,[3368]=51,[3369]=17,[3370]=17,
    [3371]=1537,[3372]=51,[3373]=1477,[3374]=8,[3375]=1337,[3376]=215,[3377]=51,[3379]=51,[3380]=1477,[3381]=16,
    [3402]=16,[3421]=16,[3441]=51,[3442]=51,[3443]=51,[3444]=440,[3445]=357,[3446]=1477,[3447]=1477,[3448]=1537,
    [3449]=1537,[3450]=1537,[3451]=1537,[3452]=51,[3453]=51,[3454]=51,[3461]=1537,[3462]=51,[3463]=51,[3481]=51,
    [3483]=1537,[3501]=4,[3502]=4,[3503]=16,[3504]=1637,[3505]=1637,[3506]=1637,[3507]=1637,[3508]=16,[3509]=16,
    [3510]=16,[3511]=16,[3512]=8,[3513]=17,[3514]=17,[3517]=16,[3518]=16,[3519]=141,[3520]=440,[3521]=141,[3522]=141,
    [3523]=722,[3524]=148,[3526]=722,[3527]=1176,[3528]=1477,[3541]=16,[3542]=16,[3561]=16,[3562]=16,[3563]=16,
    [3564]=16,[3565]=16,[3566]=51,[3567]=357,[3568]=1497,[3569]=1497,[3570]=1497,[3601]=16,[3602]=16,[3621]=16,
    [3625]=33,[3626]=33,[3627]=4,[3635]=4,[3647]=722,[3681]=702,[3701]=1537,[3702]=1537,[3721]=33,[3741]=44,
    [3761]=1638,[3762]=1638,[3763]=1657,[3764]=1657,[3765]=1519,[3781]=1657,[3782]=1638,[3783]=618,[3784]=1497,
    [3785]=1657,[3786]=1638,[3787]=1519,[3788]=1657,[3789]=1519,[3790]=1537,[3791]=1657,[3792]=1657,[3801]=1584,
    [3802]=1584,[3803]=1657,[3804]=1638,[3821]=3,[3822]=46,[3823]=46,[3824]=46,[3825]=46,[3841]=357,[3842]=357,
    [3843]=357,[3844]=490,[3861]=490,[3881]=490,[3882]=490,[3883]=490,[3884]=490,[3901]=85,[3902]=85,[3903]=12,
    [3904]=12,[3905]=12,[3906]=25,[3907]=1584,[3908]=490,[3909]=490,[3911]=1584,[3912]=490,[3913]=490,[3914]=490,
    [3921]=17,[3922]=17,[3923]=17,[3924]=17,[3941]=490,[3942]=490,[3961]=490,[3962]=490,[3981]=1584,[3982]=1584,
    [4001]=1584,[4002]=1584,[4003]=1584,[4004]=1584,[4005]=490,[4021]=17,[4022]=46,[4023]=46,[4024]=1584,[4041]=357,
    [4061]=46,[4062]=3,[4063]=1584,[4081]=1584,[4082]=1584,[4083]=1584,[4084]=490,[4101]=361,[4102]=361,[4103]=361,
    [4104]=361,[4105]=361,[4106]=361,[4107]=361,[4108]=361,[4109]=361,[4110]=361,[4111]=361,[4112]=361,[4113]=361,
    [4114]=361,[4115]=361,[4116]=361,[4117]=361,[4118]=361,[4119]=361,[4120]=357,[4121]=1584,[4122]=1584,[4123]=1584,
    [4124]=357,[4125]=357,[4126]=1584,[4127]=357,[4128]=1584,[4129]=357,[4130]=357,[4131]=357,[4132]=1584,[4133]=1584,
    [4134]=1584,[4135]=357,[4136]=1584,[4141]=490,[4142]=490,[4143]=490,[4144]=490,[4145]=490,[4146]=1477,[4147]=490,
    [4181]=490,[4182]=46,[4183]=46,[4184]=46,[4185]=46,[4186]=46,[4201]=1584,[4221]=361,[4222]=361,[4223]=46,
    [4224]=46,[4241]=1584,[4242]=1584,[4243]=490,[4244]=490,[4245]=490,[4261]=361,[4262]=25,[4263]=1584,[4264]=1584,
    [4265]=357,[4266]=357,[4267]=357,[4281]=357,[4282]=1584,[4283]=46,[4284]=490,[4285]=490,[4286]=1584,[4287]=490,
    [4288]=490,[4289]=490,[4290]=490,[4291]=490,[4292]=490,[4293]=1497,[4294]=1497,[4295]=1584,[4296]=46,[4297]=357,
    [4298]=357,[4300]=1637,[4301]=490,[4321]=490,[4322]=1584,[4324]=1584,[4341]=1584,[4342]=1584,[4343]=361,
    [4361]=1584,[4362]=1584,[4363]=1584,[4381]=490,[4382]=490,[4383]=490,[4384]=490,[4385]=490,[4386]=490,[4401]=361,
    [4402]=14,[4403]=361,[4421]=361,[4441]=361,[4442]=361,[4443]=361,[4444]=361,[4445]=361,[4446]=361,[4447]=361,
    [4448]=361,[4449]=51,[4450]=51,[4451]=51,[4461]=361,[4462]=361,[4463]=46,[4464]=361,[4465]=361,[4466]=361,
    [4467]=361,[4481]=46,[4482]=46,[4483]=46,[4490]=46,[4491]=490,[4492]=490,[4493]=1657,[4494]=1637,[4495]=141,
    [4496]=440,[4501]=490,[4502]=490,[4503]=490,[4504]=440,[4505]=361,[4506]=361,[4507]=440,[4508]=440,[4509]=440,
    [4510]=1657,[4511]=1637,[4512]=1537,[4513]=1537,[4521]=361,[4542]=400,[4561]=1497,[4581]=331,[4601]=721,
    [4602]=721,[4603]=721,[4604]=721,[4605]=721,[4606]=721,[4621]=33,[4641]=14,[4642]=1497,[4661]=1497,[4681]=148,
    [4701]=1583,[4721]=361,[4722]=148,[4723]=148,[4724]=1583,[4725]=148,[4726]=46,[4727]=148,[4728]=148,[4729]=1583,
    [4730]=148,[4731]=148,[4732]=148,[4733]=148,[4734]=1583,[4739]=1583,[4740]=148,[4741]=361,[4742]=1583,[4743]=1583,
    [4761]=148,[4762]=148,[4763]=148,[4764]=1583,[4765]=1583,[4766]=1583,[4767]=400,[4768]=1583,[4769]=1583,
    [4770]=400,[4786]=2057,[4787]=47,[4788]=1583,[4801]=618,[4802]=618,[4803]=618,[4804]=618,[4805]=618,[4806]=618,
    [4807]=618,[4808]=46,[4809]=618,[4810]=618,[4811]=148,[4812]=148,[4813]=148,[4822]=400,[4841]=400,[4842]=618,
    [4861]=618,[4862]=1583,[4863]=618,[4864]=618,[4865]=400,[4866]=1583,[4867]=1583,[4881]=400,[4882]=618,[4883]=618,
    [4901]=618,[4902]=618,[4903]=1583,[4904]=400,[4906]=361,[4907]=1583,[4921]=17,[4965]=1637,[4969]=400,[4970]=618,
    [4971]=28,[4972]=28,[4973]=28,[4976]=1583,[4981]=1583,[4982]=1583,[4983]=1583,[4984]=28,[4985]=28,[4986]=28,
    [4987]=28,[5001]=1583,[5002]=1583,[5021]=28,[5022]=28,[5023]=28,[5041]=17,[5042]=17,[5043]=17,[5044]=17,[5045]=17,
    [5046]=17,[5047]=1583,[5048]=1519,[5049]=1497,[5050]=28,[5051]=28,[5052]=17,[5054]=618,[5055]=618,[5056]=618,
    [5057]=618,[5058]=28,[5059]=28,[5061]=28,[5062]=400,[5063]=618,[5064]=400,[5065]=139,[5066]=1519,[5067]=618,
    [5068]=618,[5081]=1583,[5082]=618,[5083]=618,[5084]=618,[5085]=618,[5086]=618,[5087]=618,[5088]=400,[5089]=1583,
    [5090]=1537,[5091]=1657,[5092]=28,[5093]=28,[5094]=28,[5095]=28,[5096]=28,[5097]=28,[5101]=28,[5103]=1583,
    [5121]=618,[5122]=2017,[5123]=618,[5124]=618,[5125]=2017,[5126]=618,[5127]=1583,[5141]=618,[5146]=139,[5148]=400,
    [5149]=139,[5150]=490,[5151]=400,[5152]=139,[5153]=139,[5154]=28,[5155]=361,[5156]=361,[5157]=361,[5158]=361,
    [5159]=361,[5160]=1583,[5161]=618,[5162]=28,[5163]=618,[5164]=28,[5165]=361,[5166]=28,[5167]=28,[5168]=139,
    [5181]=139,[5201]=618,[5202]=361,[5203]=361,[5204]=361,[5206]=139,[5210]=139,[5211]=139,[5212]=2017,[5213]=2017,
    [5214]=2017,[5215]=28,[5216]=28,[5217]=28,[5218]=28,[5219]=28,[5220]=28,[5221]=28,[5222]=28,[5223]=28,[5224]=28,
    [5225]=28,[5226]=28,[5227]=28,[5228]=28,[5229]=28,[5230]=28,[5231]=28,[5232]=28,[5233]=28,[5234]=28,[5235]=28,
    [5236]=28,[5237]=28,[5238]=28,[5241]=139,[5242]=361,[5243]=2017,[5244]=618,[5245]=618,[5246]=139,[5247]=139,
    [5248]=139,[5249]=361,[5250]=702,[5251]=2017,[5252]=618,[5253]=618,[5261]=12,[5262]=2017,[5263]=2017,[5264]=139,
    [5265]=139,[5281]=139,[5307]=2017,[5321]=148,[5341]=2057,[5342]=28,[5343]=2057,[5344]=28,[5361]=400,[5381]=405,
    [5382]=2057,[5383]=2057,[5384]=2057,[5385]=361,[5386]=405,[5401]=28,[5402]=28,[5403]=28,[5404]=28,[5405]=28,
    [5406]=28,[5407]=28,[5408]=28,[5421]=405,[5441]=14,[5461]=28,[5462]=28,[5463]=2017,[5464]=139,[5465]=28,
    [5466]=2057,[5481]=85,[5482]=85,[5502]=405,[5503]=139,[5504]=28,[5505]=28,[5507]=28,[5508]=139,[5509]=139,
    [5510]=139,[5511]=28,[5513]=139,[5514]=28,[5515]=2057,[5517]=139,[5518]=2557,[5519]=2557,[5521]=28,[5522]=46,
    [5524]=28,[5525]=2557,[5526]=493,[5527]=493,[5528]=2557,[5529]=2057,[5531]=2057,[5533]=28,[5534]=16,[5535]=16,
    [5536]=16,[5537]=28,[5538]=28,[5541]=1,[5542]=139,[5543]=139,[5544]=139,[5545]=12,[5561]=405,[5581]=405,
    [5582]=2057,[5680]=139,[5713]=148,[5721]=139,[5722]=2437,[5723]=2437,[5724]=2437,[5725]=2437,[5726]=1637,
    [5727]=1637,[5728]=2437,[5729]=1637,[5730]=1637,[5741]=405,[5742]=139,[5761]=2437,[5762]=400,[5763]=405,
    [5781]=139,[5801]=440,[5802]=440,[5803]=28,[5804]=28,[5805]=12,[5821]=405,[5841]=1,[5842]=141,[5843]=14,
    [5844]=215,[5845]=139,[5846]=139,[5847]=85,[5848]=2017,[5861]=28,[5862]=28,[5863]=440,[5881]=406,[5882]=361,
    [5883]=361,[5884]=361,[5885]=361,[5886]=361,[5887]=361,[5888]=361,[5889]=361,[5890]=361,[5891]=361,[5892]=2597,
    [5893]=2597,[5901]=139,[5902]=85,[5903]=139,[5932]=28,[5941]=139,[5942]=139,[5943]=405,[5944]=28,[5961]=1497,
    [6002]=618,[6004]=28,[6021]=139,[6022]=139,[6023]=28,[6024]=139,[6025]=28,[6026]=139,[6027]=405,[6028]=618,
    [6029]=618,[6030]=618,[6031]=1216,[6032]=1216,[6041]=139,[6130]=139,[6131]=361,[6132]=405,[6133]=139,[6134]=405,
    [6135]=139,[6136]=139,[6141]=405,[6142]=405,[6143]=405,[6144]=139,[6145]=139,[6146]=139,[6147]=139,[6148]=139,
    [6161]=405,[6162]=361,[6163]=2017,[6164]=139,[6181]=40,[6182]=1519,[6183]=1519,[6184]=28,[6185]=139,[6186]=1519,
    [6187]=139,[6221]=1216,[6241]=1216,[6261]=40,[6281]=40,[6282]=406,[6283]=406,[6284]=406,[6285]=40,[6301]=406,
    [6321]=130,[6322]=130,[6323]=130,[6324]=130,[6341]=148,[6342]=148,[6343]=148,[6344]=1657,[6361]=17,[6362]=17,
    [6363]=17,[6364]=17,[6365]=17,[6381]=406,[6382]=17,[6383]=331,[6384]=17,[6385]=17,[6386]=17,[6387]=38,[6388]=38,
    [6389]=28,[6390]=28,[6391]=38,[6392]=38,[6393]=406,[6394]=14,[6395]=85,[6401]=406,[6402]=1519,[6403]=1519,
    [6421]=406,[6441]=331,[6442]=331,[6461]=406,[6462]=331,[6481]=406,[6482]=331,[6501]=1519,[6502]=1583,[6503]=331,
    [6504]=331,[6521]=722,[6522]=722,[6523]=406,[6541]=17,[6542]=406,[6543]=331,[6544]=331,[6545]=331,[6546]=331,
    [6547]=331,[6548]=406,[6561]=719,[6562]=719,[6563]=719,[6564]=719,[6565]=719,[6566]=1637,[6567]=1637,[6568]=405,
    [6569]=1583,[6570]=15,[6571]=331,[6581]=331,[6582]=15,[6583]=15,[6584]=15,[6585]=15,[6601]=15,[6602]=1583,
    [6603]=618,[6604]=618,[6605]=618,[6612]=618,[6625]=331,[6626]=722,[6627]=400,[6628]=400,[6629]=406,[6641]=331,
    [6642]=2717,[6643]=2717,[6644]=2717,[6645]=2717,[6646]=2717,[6661]=2257,[6701]=2257,[6721]=1537,[6722]=131,
    [6741]=2597,[6761]=1657,[6762]=1657,[6781]=2597,[6801]=2597,[6804]=16,[6805]=16,[6821]=16,[6822]=16,[6823]=16,
    [6824]=16,[6825]=2597,[6826]=2597,[6827]=2597,[6844]=1377,[6845]=493,[6846]=2597,[6847]=2597,[6848]=2597,
    [6861]=2597,[6862]=2597,[6881]=2597,[6901]=2597,[6921]=719,[6922]=331,[6941]=2597,[6942]=2597,[6964]=2597,
    [6981]=718,[6984]=2597,[6985]=2597,[7001]=2597,[7002]=2597,[7025]=357,[7026]=2597,[7027]=2597,[7028]=2100,
    [7029]=2100,[7043]=2100,[7045]=2100,[7063]=2100,[7064]=2100,[7065]=2100,[7066]=2100,[7067]=2100,[7068]=2100,
    [7070]=2100,[7081]=2597,[7082]=2597,[7101]=2597,[7102]=2597,[7121]=2597,[7122]=2597,[7123]=2597,[7124]=2597,
    [7141]=2597,[7142]=2597,[7161]=2597,[7162]=2597,[7163]=2597,[7164]=2597,[7165]=2597,[7166]=2597,[7167]=2597,
    [7168]=2597,[7169]=2597,[7170]=2597,[7171]=2597,[7172]=2597,[7181]=2597,[7201]=1584,[7202]=2597,[7221]=2597,
    [7222]=2597,[7223]=2597,[7224]=2597,[7241]=2597,[7261]=2597,[7281]=2597,[7282]=2597,[7301]=2597,[7321]=2597,
    [7341]=1637,[7342]=1537,[7367]=2597,[7368]=2597,[7383]=141,[7385]=2597,[7386]=2597,[7429]=2557,[7441]=2557,
    [7461]=2557,[7462]=2557,[7463]=2557,[7481]=2557,[7482]=2557,[7483]=2557,[7484]=2557,[7485]=2557,[7486]=16,
    [7487]=2717,[7488]=2557,[7489]=2557,[7490]=1637,[7491]=1637,[7492]=2557,[7493]=1637,[7494]=2557,[7495]=1519,
    [7496]=1519,[7497]=1519,[7498]=2557,[7499]=2557,[7500]=2557,[7501]=2557,[7502]=2557,[7503]=2557,[7504]=2557,
    [7505]=2557,[7506]=2557,[7507]=2557,[7508]=2557,[7509]=2159,[7603]=15,[7659]=1584,[7701]=51,[7702]=51,[7703]=2557,
    [7704]=51,[7721]=357,[7722]=51,[7723]=51,[7724]=51,[7725]=357,[7726]=357,[7727]=51,[7728]=51,[7729]=51,[7730]=357,
    [7731]=357,[7732]=357,[7733]=357,[7734]=357,[7735]=357,[7736]=51,[7737]=51,[7738]=357,[7761]=1583,[7781]=1519,
    [7782]=1519,[7783]=1637,[7787]=1637,[7788]=3277,[7789]=3277,[7791]=1519,[7792]=3557,[7793]=1519,[7794]=1519,
    [7795]=1519,[7796]=1519,[7798]=3557,[7799]=1657,[7800]=1657,[7801]=1657,[7802]=1537,[7803]=1537,[7804]=1537,
    [7805]=1537,[7806]=1537,[7807]=1537,[7808]=1537,[7809]=1537,[7810]=33,[7811]=1537,[7812]=1537,[7813]=1497,
    [7814]=1497,[7815]=47,[7816]=47,[7817]=1497,[7818]=1497,[7819]=1497,[7820]=1638,[7821]=1638,[7822]=1638,
    [7823]=1638,[7824]=1637,[7825]=1638,[7826]=1637,[7827]=1637,[7828]=47,[7829]=47,[7830]=47,[7831]=1637,[7832]=1637,
    [7833]=1637,[7834]=1637,[7835]=1637,[7836]=1637,[7837]=1637,[7839]=47,[7840]=47,[7841]=47,[7842]=47,[7843]=47,
    [7844]=47,[7845]=47,[7846]=47,[7847]=47,[7848]=2717,[7849]=47,[7850]=47,[7861]=47,[7862]=47,[7863]=331,[7864]=331,
    [7865]=331,[7866]=331,[7867]=331,[7868]=331,[7871]=3277,[7872]=3277,[7873]=3277,[7874]=3277,[7875]=3277,
    [7876]=3277,[7903]=2557,[7907]=1537,[7908]=33,[7946]=1637,[7981]=12,[8041]=1977,[8042]=1977,[8043]=1977,
    [8044]=1977,[8045]=1977,[8046]=1977,[8047]=1977,[8048]=1977,[8049]=1977,[8050]=1977,[8051]=1977,[8052]=1977,
    [8053]=1977,[8054]=1977,[8055]=1977,[8056]=1977,[8057]=1977,[8058]=1977,[8059]=1977,[8060]=1977,[8061]=1977,
    [8062]=1977,[8063]=1977,[8064]=1977,[8065]=1977,[8066]=1977,[8067]=1977,[8068]=1977,[8069]=1977,[8070]=1977,
    [8071]=1977,[8072]=1977,[8073]=1977,[8074]=1977,[8075]=1977,[8076]=1977,[8077]=1977,[8078]=1977,[8079]=1977,
    [8080]=3358,[8101]=1977,[8102]=1977,[8103]=1977,[8104]=1977,[8105]=3358,[8106]=1977,[8107]=1977,[8108]=1977,
    [8109]=1977,[8110]=1977,[8111]=1977,[8112]=1977,[8113]=1977,[8114]=3358,[8115]=3358,[8116]=1977,[8117]=1977,
    [8118]=1977,[8119]=1977,[8120]=3358,[8121]=3358,[8122]=3358,[8123]=3358,[8141]=1977,[8142]=1977,[8143]=1977,
    [8144]=1977,[8145]=1977,[8146]=1977,[8147]=1977,[8153]=1977,[8154]=3358,[8155]=3358,[8156]=3358,[8160]=3358,
    [8161]=3358,[8162]=3358,[8166]=3358,[8167]=3358,[8168]=3358,[8169]=3358,[8170]=3358,[8171]=3358,[8181]=1977,
    [8182]=440,[8183]=1977,[8184]=1977,[8185]=1977,[8186]=1977,[8187]=1977,[8188]=1977,[8189]=1977,[8190]=1977,
    [8191]=1977,[8194]=1977,[8195]=1977,[8196]=1977,[8225]=1977,[8227]=1977,[8238]=1977,[8239]=1977,[8240]=1977,
    [8241]=51,[8242]=51,[8243]=1977,[8259]=1977,[8260]=3358,[8261]=3358,[8262]=3358,[8263]=3358,[8264]=3358,
    [8265]=3358,[8266]=3277,[8268]=3277,[8271]=2597,[8272]=2597,[8273]=47,[8275]=1537,[8276]=1637,[8277]=1377,
    [8278]=1377,[8279]=1377,[8280]=1377,[8281]=1377,[8282]=1377,[8283]=1377,[8284]=1377,[8285]=1377,[8286]=1377,
    [8287]=1377,[8288]=2677,[8290]=3277,[8291]=3277,[8294]=3277,[8295]=3277,[8297]=3358,[8299]=3358,[8301]=1377,
    [8302]=1377,[8303]=1377,[8304]=1377,[8305]=1377,[8307]=1377,[8308]=1377,[8309]=1377,[8313]=1377,[8314]=1377,
    [8315]=1377,[8317]=1377,[8318]=1377,[8319]=1377,[8320]=1377,[8322]=1377,[8323]=1377,[8324]=1377,[8325]=3430,
    [8326]=3430,[8328]=3430,[8330]=3430,[8331]=1377,[8332]=1377,[8333]=1377,[8334]=3430,[8335]=3430,[8336]=3430,
    [8338]=3430,[8339]=1377,[8341]=1377,[8342]=1377,[8344]=1377,[8345]=3430,[8346]=3430,[8347]=3430,[8348]=1377,
    [8349]=1377,[8350]=3430,[8351]=1377,[8360]=1377,[8361]=1377,[8362]=1377,[8363]=1377,[8364]=1377,[8365]=440,
    [8367]=440,[8368]=3277,[8369]=2597,[8371]=3358,[8373]=3277,[8374]=3358,[8375]=2839,[8376]=1377,[8377]=1377,
    [8378]=1377,[8379]=1377,[8380]=1377,[8381]=1377,[8382]=1377,[8383]=2839,[8385]=45,[8386]=3277,[8388]=2839,
    [8389]=3277,[8390]=3358,[8391]=3358,[8392]=3358,[8393]=3358,[8394]=3358,[8395]=3358,[8396]=3358,[8397]=3358,
    [8398]=3358,[8399]=3277,[8400]=3277,[8401]=3277,[8402]=3277,[8403]=3277,[8407]=3277,[8426]=3277,[8427]=3277,
    [8428]=3277,[8429]=3277,[8430]=3277,[8431]=3277,[8432]=3277,[8433]=3277,[8434]=3277,[8435]=3277,[8436]=3358,
    [8437]=3358,[8438]=45,[8439]=3358,[8440]=3358,[8441]=3358,[8442]=3358,[8447]=3358,[8460]=361,[8461]=1216,
    [8462]=361,[8463]=3430,[8464]=1216,[8465]=361,[8466]=361,[8467]=361,[8468]=3430,[8469]=361,[8470]=361,[8471]=618,
    [8472]=3430,[8473]=3430,[8474]=3430,[8475]=3430,[8476]=3430,[8477]=3430,[8479]=3430,[8480]=3430,[8481]=1216,
    [8482]=3430,[8483]=3430,[8484]=1216,[8485]=1216,[8486]=3430,[8487]=3430,[8488]=3430,[8489]=3430,[8490]=3430,
    [8495]=3430,[8496]=1377,[8497]=1377,[8500]=1377,[8501]=1377,[8506]=1377,[8507]=1377,[8518]=1377,[8533]=1377,
    [8534]=1377,[8535]=1377,[8536]=1377,[8537]=1377,[8538]=1377,[8539]=1377,[8540]=1377,[8543]=1377,[8546]=3428,
    [8547]=3430,[8550]=1377,[8551]=33,[8552]=33,[8553]=33,[8554]=33,[8555]=440,[8556]=3428,[8557]=3428,[8558]=3428,
    [8559]=3428,[8560]=3428,[8561]=3428,[8564]=3428,[8572]=1377,[8573]=1377,[8574]=1377,[8575]=16,[8576]=440,
    [8577]=440,[8578]=2717,[8583]=3428,[8584]=440,[8585]=440,[8586]=440,[8591]=440,[8592]=3428,[8593]=3428,
    [8594]=3428,[8595]=3428,[8596]=3428,[8597]=440,[8598]=440,[8601]=440,[8602]=3428,[8605]=3428,[8619]=440,
    [8620]=440,[8621]=3428,[8622]=3428,[8623]=3428,[8624]=3428,[8625]=3428,[8626]=3428,[8627]=3428,[8628]=3428,
    [8629]=3428,[8630]=3428,[8631]=3428,[8632]=3428,[8633]=3428,[8636]=3428,[8637]=3428,[8638]=3428,[8639]=3428,
    [8640]=3428,[8654]=3428,[8655]=3428,[8656]=3428,[8657]=3428,[8658]=3428,[8659]=3428,[8660]=3428,[8661]=3428,
    [8662]=3428,[8663]=3428,[8664]=3428,[8665]=3428,[8666]=3428,[8667]=3428,[8668]=3428,[8686]=3428,[8688]=1377,
    [8689]=3428,[8690]=3428,[8691]=3428,[8692]=3428,[8693]=3428,[8694]=3428,[8695]=3428,[8696]=3428,[8697]=3428,
    [8698]=3428,[8699]=3428,[8700]=3428,[8701]=3428,[8702]=3428,[8703]=3428,[8704]=3428,[8705]=3428,[8706]=3428,
    [8707]=3428,[8708]=3428,[8709]=3428,[8710]=3428,[8711]=3428,[8727]=3428,[8728]=440,[8729]=16,[8730]=2677,
    [8731]=1377,[8732]=1377,[8733]=1477,[8734]=141,[8735]=493,[8736]=493,[8737]=1377,[8738]=1377,[8739]=1377,
    [8740]=1377,[8741]=493,[8742]=440,[8744]=1377,[8746]=1377,[8747]=440,[8748]=440,[8749]=440,[8750]=440,[8751]=440,
    [8752]=440,[8753]=440,[8754]=440,[8755]=440,[8756]=440,[8757]=440,[8758]=440,[8759]=440,[8760]=440,[8763]=440,
    [8764]=440,[8765]=440,[8769]=440,[8770]=1377,[8771]=1377,[8772]=1377,[8773]=1377,[8774]=1377,[8775]=1377,
    [8776]=1377,[8777]=1377,[8778]=1377,[8779]=1377,[8780]=1377,[8781]=1377,[8782]=1377,[8783]=1377,[8784]=3428,
    [8785]=1377,[8786]=1377,[8788]=1377,[8789]=3428,[8790]=3428,[8797]=3429,[8799]=618,[8800]=1377,[8801]=3428,
    [8803]=3428,[8804]=1377,[8805]=1377,[8806]=1377,[8807]=1377,[8808]=1377,[8809]=1377,[8828]=1377,[8855]=1377,
    [8856]=1377,[8857]=1377,[8858]=1377,[8883]=1377,[8884]=3430,[8885]=3430,[8886]=3430,[8887]=3430,[8888]=3430,
    [8889]=3430,[8890]=3430,[8891]=3430,[8892]=3430,[8893]=440,[8894]=3430,[8895]=3430,[8904]=3430,[8905]=1537,
    [8906]=1537,[8907]=1537,[8908]=1537,[8909]=1537,[8910]=1537,[8911]=1537,[8912]=1537,[8913]=1637,[8914]=1637,
    [8915]=1637,[8916]=1637,[8917]=1637,[8918]=1637,[8919]=1637,[8920]=1637,[8921]=440,[8922]=440,[8923]=440,
    [8924]=440,[8925]=440,[8926]=1537,[8927]=1637,[8928]=440,[8929]=139,[8930]=139,[8931]=1537,[8932]=1537,
    [8933]=1537,[8934]=1537,[8935]=1537,[8936]=1537,[8937]=1537,[8938]=1637,[8939]=1637,[8940]=1637,[8941]=1637,
    [8942]=1637,[8943]=1637,[8944]=1637,[8945]=2017,[8946]=139,[8947]=139,[8948]=2557,[8949]=2557,[8950]=2557,
    [8951]=1537,[8952]=1537,[8953]=1537,[8954]=1537,[8955]=1537,[8956]=1537,[8957]=1637,[8958]=1537,[8959]=1537,
    [8960]=25,[8961]=25,[8962]=25,[8963]=25,[8964]=25,[8965]=25,[8966]=1583,[8967]=2557,[8968]=2017,[8969]=2057,
    [8970]=15,[8977]=1537,[8984]=1637,[8985]=25,[8986]=25,[8987]=25,[8988]=25,[8989]=1583,[8990]=2557,[8991]=2017,
    [8993]=2057,[8994]=25,[8995]=1583,[8996]=25,[8997]=1537,[8998]=1637,[8999]=1537,[9000]=1537,[9001]=1537,
    [9002]=1537,[9003]=1537,[9004]=1537,[9005]=1537,[9006]=1537,[9007]=1637,[9008]=1637,[9009]=1637,[9010]=1637,
    [9011]=1637,[9012]=1637,[9013]=1637,[9014]=1637,[9015]=1584,[9016]=1637,[9017]=1637,[9018]=1637,[9019]=1637,
    [9020]=1637,[9021]=1637,[9022]=1637,[9028]=1377,[9030]=2557,[9032]=25,[9033]=3456,[9034]=3456,[9035]=3430,
    [9036]=3456,[9037]=3456,[9038]=3456,[9039]=3456,[9040]=3456,[9041]=3456,[9042]=3456,[9043]=3456,[9044]=3456,
    [9045]=3456,[9046]=3456,[9047]=3456,[9048]=3456,[9049]=3456,[9053]=3456,[9054]=3456,[9055]=3456,[9056]=3456,
    [9057]=3456,[9058]=3456,[9059]=3456,[9060]=3456,[9061]=3456,[9063]=3430,[9064]=3430,[9065]=22,[9066]=3430,
    [9067]=3430,[9068]=3456,[9069]=3456,[9070]=3456,[9071]=3456,[9072]=3456,[9073]=3456,[9074]=3456,[9075]=3456,
    [9076]=3430,[9077]=3456,[9078]=3456,[9079]=3456,[9080]=3456,[9081]=3456,[9082]=3456,[9083]=3456,[9085]=3456,
    [9086]=3456,[9087]=3456,[9088]=3456,[9089]=3456,[9090]=3456,[9091]=3456,[9092]=3456,[9093]=3456,[9095]=3456,
    [9096]=3456,[9097]=3456,[9098]=3456,[9099]=3456,[9100]=3456,[9101]=3456,[9102]=3456,[9103]=3456,[9104]=3456,
    [9105]=3456,[9106]=3456,[9107]=3456,[9108]=3456,[9109]=3456,[9110]=3456,[9111]=3456,[9112]=3456,[9113]=3456,
    [9114]=3456,[9115]=3456,[9116]=3456,[9117]=3456,[9118]=3456,[9119]=3430,[9120]=3456,[9121]=139,[9122]=139,
    [9123]=139,[9124]=139,[9125]=139,[9126]=139,[9127]=139,[9128]=139,[9129]=139,[9130]=3433,[9131]=139,[9132]=139,
    [9133]=3433,[9134]=3433,[9135]=3433,[9136]=139,[9137]=139,[9138]=3433,[9139]=3433,[9140]=3433,[9141]=139,
    [9142]=139,[9143]=3433,[9144]=3433,[9145]=3433,[9146]=3433,[9147]=3433,[9148]=3433,[9149]=3433,[9150]=3433,
    [9151]=3433,[9154]=3433,[9155]=3433,[9156]=3433,[9157]=3433,[9158]=3433,[9159]=3433,[9160]=3433,[9161]=3433,
    [9162]=3433,[9163]=3433,[9164]=3433,[9165]=139,[9166]=3433,[9167]=3433,[9168]=3433,[9169]=3433,[9170]=3433,
    [9171]=3433,[9172]=3433,[9173]=3433,[9174]=3433,[9175]=3433,[9176]=3433,[9177]=1497,[9178]=139,[9179]=139,
    [9180]=1497,[9181]=139,[9182]=139,[9183]=139,[9184]=139,[9185]=139,[9186]=139,[9187]=139,[9188]=139,[9189]=130,
    [9190]=139,[9191]=139,[9192]=3433,[9193]=3433,[9194]=139,[9195]=139,[9196]=139,[9197]=139,[9198]=139,[9199]=3433,
    [9200]=139,[9201]=139,[9202]=139,[9203]=139,[9204]=139,[9205]=139,[9206]=139,[9207]=3433,[9208]=1977,[9209]=1977,
    [9210]=1977,[9211]=139,[9212]=3433,[9213]=139,[9214]=3433,[9215]=3433,[9216]=3433,[9217]=3433,[9218]=3433,
    [9219]=3433,[9220]=3433,[9221]=139,[9222]=139,[9223]=139,[9224]=139,[9225]=139,[9226]=139,[9227]=139,[9228]=139,
    [9229]=3456,[9230]=3456,[9232]=3456,[9233]=3456,[9234]=3456,[9235]=3456,[9236]=3456,[9237]=3456,[9238]=3456,
    [9239]=3456,[9240]=3456,[9241]=3456,[9242]=3456,[9243]=3456,[9244]=3456,[9245]=3456,[9247]=3456,[9251]=1377,
    [9252]=3430,[9253]=3430,[9254]=3430,[9255]=3430,[9257]=3430,[9258]=3430,[9265]=33,[9266]=33,[9267]=17,[9271]=440,
    [9272]=33,[9274]=3433,[9275]=3433,[9276]=3433,[9277]=3433,[9278]=3524,[9279]=3524,[9280]=3524,[9281]=3433,
    [9282]=3433,[9283]=3524,[9293]=3524,[9302]=3524,[9304]=3524,[9305]=3524,[9310]=3524,[9311]=3524,[9312]=3524,
    [9313]=3524,[9314]=3524,[9315]=3433,[9327]=3433,[9328]=3433,[9332]=3433,[9339]=1377,[9341]=3483,[9343]=3483,
    [9344]=3483,[9345]=3483,[9346]=3483,[9349]=3483,[9351]=3483,[9352]=3430,[9355]=3483,[9356]=3483,[9357]=3430,
    [9358]=3430,[9359]=3430,[9360]=3430,[9362]=3483,[9365]=3430,[9368]=3483,[9369]=3524,[9370]=3483,[9371]=3524,
    [9372]=3483,[9373]=3483,[9374]=3483,[9375]=3483,[9376]=3483,[9380]=3483,[9381]=3483,[9382]=3483,[9383]=3483,
    [9386]=3483,[9389]=3483,[9390]=3483,[9393]=3483,[9394]=3430,[9395]=3430,[9396]=3483,[9397]=3483,[9398]=3483,
    [9399]=3483,[9400]=3483,[9404]=3483,[9405]=3483,[9406]=3483,[9407]=3483,[9408]=3483,[9409]=3524,[9410]=3483,
    [9415]=1377,[9416]=1377,[9417]=3483,[9418]=3483,[9419]=1377,[9421]=3483,[9422]=1377,[9423]=3483,[9424]=3483,
    [9425]=267,[9426]=3483,[9427]=3483,[9428]=331,[9429]=10,[9430]=3483,[9431]=400,[9432]=331,[9433]=400,[9434]=400,
    [9435]=267,[9436]=33,[9437]=15,[9438]=3483,[9439]=3,[9440]=8,[9441]=3483,[9442]=3483,[9443]=28,[9444]=28,
    [9446]=28,[9447]=3483,[9451]=8,[9452]=3524,[9453]=3524,[9454]=3524,[9455]=3524,[9456]=3524,[9462]=33,[9465]=3524,
    [9468]=3483,[9469]=47,[9470]=47,[9471]=47,[9472]=3483,[9473]=3524,[9474]=28,[9475]=47,[9476]=47,[9489]=3483,
    [9491]=3483,[9492]=3535,[9493]=3535,[9494]=3535,[9495]=3535,[9496]=3535,[9498]=3483,[9504]=3483,[9505]=3524,
    [9509]=3524,[9510]=3483,[9511]=3483,[9512]=3524,[9513]=3524,[9514]=3524,[9515]=3524,[9516]=331,[9517]=331,
    [9518]=331,[9519]=331,[9520]=331,[9521]=331,[9522]=331,[9523]=3524,[9524]=3535,[9525]=3535,[9526]=331,[9527]=3524,
    [9529]=3524,[9530]=3524,[9532]=3524,[9533]=331,[9534]=331,[9535]=331,[9536]=331,[9537]=3524,[9538]=3524,
    [9539]=3524,[9540]=3524,[9541]=3524,[9542]=3524,[9543]=3483,[9544]=3524,[9547]=3483,[9548]=3525,[9549]=3525,
    [9555]=3525,[9557]=3525,[9558]=3483,[9559]=3524,[9560]=3524,[9561]=3525,[9562]=3524,[9563]=3483,[9564]=3524,
    [9565]=3524,[9566]=3524,[9567]=3525,[9568]=3525,[9569]=3525,[9570]=3524,[9571]=3524,[9572]=3535,[9573]=3524,
    [9574]=3525,[9575]=3535,[9576]=3525,[9578]=3525,[9579]=3525,[9580]=3525,[9582]=3525,[9584]=3525,[9586]=3525,
    [9587]=3483,[9588]=3483,[9589]=3535,[9593]=3535,[9601]=3525,[9602]=3524,[9603]=3525,[9604]=3525,[9605]=3525,
    [9606]=3525,[9607]=3535,[9608]=3535,[9609]=8,[9610]=8,[9612]=3524,[9619]=3524,[9620]=3525,[9621]=1497,[9622]=3524,
    [9623]=3524,[9624]=3525,[9625]=3524,[9626]=1637,[9627]=3487,[9628]=3525,[9629]=3525,[9630]=3457,[9631]=3523,
    [9632]=3525,[9633]=3525,[9636]=3525,[9637]=3457,[9638]=3457,[9639]=3457,[9640]=3457,[9641]=3525,[9642]=3525,
    [9643]=3525,[9644]=3457,[9645]=3457,[9646]=3525,[9647]=3525,[9648]=3525,[9649]=3525,[9663]=3525,[9664]=139,
    [9665]=139,[9666]=3525,[9667]=3525,[9668]=3525,[9669]=3525,[9670]=3525,[9671]=3525,[9673]=3525,[9678]=3525,
    [9681]=41,[9682]=3525,[9686]=3525,[9687]=3525,[9688]=3525,[9692]=3525,[9693]=3525,[9694]=3525,[9696]=3525,
    [9697]=3521,[9698]=3525,[9699]=3525,[9700]=3525,[9701]=3521,[9702]=3521,[9703]=3525,[9704]=3430,[9705]=3430,
    [9707]=3525,[9708]=3521,[9710]=3521,[9712]=3525,[9714]=3716,[9715]=3716,[9716]=3521,[9717]=3716,[9718]=3521,
    [9719]=3716,[9723]=3521,[9725]=3521,[9726]=3521,[9727]=3521,[9728]=3521,[9729]=3521,[9730]=3521,[9731]=3521,
    [9732]=3521,[9733]=3521,[9737]=3521,[9738]=3607,[9739]=3521,[9740]=3525,[9741]=3525,[9742]=3521,[9743]=3521,
    [9744]=3521,[9746]=3525,[9747]=3521,[9748]=3525,[9749]=3525,[9750]=3525,[9751]=3525,[9752]=3521,[9753]=3525,
    [9757]=3525,[9758]=3433,[9759]=3525,[9760]=3525,[9761]=3525,[9762]=3525,[9763]=3715,[9764]=3715,[9765]=3715,
    [9766]=3607,[9767]=3607,[9769]=3521,[9770]=3521,[9771]=3521,[9772]=3521,[9773]=3521,[9774]=3521,[9775]=3521,
    [9776]=3521,[9777]=3521,[9778]=3521,[9779]=3525,[9780]=3521,[9781]=3521,[9782]=3521,[9783]=3521,[9784]=3521,
    [9785]=3521,[9786]=3521,[9787]=3521,[9788]=3521,[9789]=3518,[9790]=3521,[9791]=3521,[9792]=3521,[9793]=3521,
    [9794]=3522,[9795]=3522,[9796]=3521,[9797]=3521,[9798]=3524,[9799]=3524,[9800]=3518,[9801]=3521,[9802]=3521,
    [9803]=3521,[9804]=3518,[9805]=3518,[9806]=3521,[9807]=3521,[9808]=3521,[9809]=3521,[9810]=3518,[9811]=3433,
    [9812]=1497,[9813]=1637,[9814]=3521,[9815]=3518,[9816]=3521,[9817]=3521,[9818]=3518,[9819]=3518,[9820]=3521,
    [9821]=3518,[9822]=3521,[9823]=3521,[9824]=3457,[9825]=3457,[9826]=36,[9827]=3521,[9828]=3521,[9829]=3703,
    [9830]=3521,[9831]=3789,[9832]=3703,[9833]=3521,[9834]=3521,[9835]=3521,[9836]=1941,[9837]=3703,[9838]=3457,
    [9839]=3521,[9840]=3457,[9841]=3521,[9842]=3521,[9843]=3457,[9844]=3457,[9845]=3521,[9846]=3521,[9847]=3521,
    [9848]=3521,[9849]=3518,[9850]=3518,[9851]=3518,[9852]=3518,[9853]=3518,[9854]=3518,[9855]=3518,[9856]=3518,
    [9857]=3518,[9858]=3518,[9859]=3518,[9860]=36,[9861]=3518,[9862]=3518,[9863]=3518,[9864]=3518,[9865]=3518,
    [9866]=3518,[9867]=3518,[9868]=3518,[9869]=3518,[9870]=3518,[9871]=3518,[9872]=3518,[9873]=3518,[9874]=3518,
    [9875]=3521,[9876]=3607,[9877]=3433,[9878]=3518,[9879]=3518,[9882]=3518,[9883]=3518,[9884]=3518,[9885]=3518,
    [9886]=3518,[9887]=3518,[9888]=3519,[9889]=3519,[9890]=3519,[9891]=3518,[9892]=3518,[9893]=3518,[9894]=3521,
    [9895]=3521,[9896]=3521,[9897]=3518,[9898]=3521,[9899]=3521,[9900]=3518,[9901]=3521,[9902]=3521,[9903]=3521,
    [9904]=3521,[9905]=3521,[9906]=3518,[9907]=3518,[9910]=3518,[9911]=3521,[9912]=3521,[9913]=3518,[9914]=3518,
    [9915]=3518,[9916]=3518,[9917]=3518,[9918]=3518,[9919]=3521,[9920]=3518,[9921]=3518,[9922]=3518,[9923]=3518,
    [9924]=3518,[9925]=3518,[9926]=3518,[9927]=3518,[9928]=3518,[9929]=3519,[9930]=3519,[9931]=3518,[9932]=3518,
    [9933]=3518,[9934]=3518,[9935]=3518,[9936]=3518,[9937]=3518,[9938]=3518,[9939]=3518,[9940]=3518,[9941]=3519,
    [9942]=3519,[9943]=3519,[9944]=3518,[9945]=3518,[9946]=3518,[9947]=3519,[9948]=3518,[9949]=3519,[9950]=3519,
    [9951]=3519,[9952]=3519,[9953]=3519,[9954]=3518,[9955]=3518,[9956]=3518,[9957]=3519,[9958]=3519,[9959]=3519,
    [9960]=3519,[9961]=3519,[9962]=3518,[9963]=3519,[9964]=3519,[9965]=3519,[9966]=3519,[9967]=3518,[9968]=3519,
    [9969]=3519,[9970]=3518,[9971]=3519,[9972]=3518,[9973]=3518,[9974]=3519,[9975]=3519,[9976]=3519,[9977]=3518,
    [9978]=3519,[9979]=3703,[9980]=3519,[9981]=3519,[9982]=3518,[9983]=3518,[9984]=3519,[9985]=3519,[9986]=3519,
    [9987]=3519,[9988]=3519,[9989]=3519,[9990]=3519,[9991]=3518,[9992]=3519,[9993]=3519,[9994]=3519,[9995]=3519,
    [9996]=3519,[9997]=3519,[9998]=3519,[9999]=3518,[10000]=3519,[10001]=3518,[10002]=3519,[10003]=3519,[10004]=3518,
    [10005]=3519,[10006]=3519,[10007]=3519,[10008]=3519,[10009]=3519,[10010]=3519,[10011]=3518,[10012]=3519,
    [10013]=3519,[10014]=3519,[10015]=3519,[10016]=3519,[10017]=3703,[10018]=3519,[10019]=3703,[10020]=3703,
    [10021]=3703,[10022]=3519,[10023]=3519,[10024]=3703,[10025]=3703,[10026]=3519,[10027]=3519,[10028]=3519,
    [10029]=3519,[10030]=3519,[10031]=3519,[10033]=3519,[10034]=3519,[10035]=3519,[10036]=3519,[10037]=3519,
    [10038]=3519,[10039]=3519,[10040]=3519,[10041]=3519,[10042]=3519,[10043]=3519,[10044]=3518,[10045]=3518,
    [10046]=3483,[10047]=3483,[10048]=3519,[10049]=3519,[10050]=3483,[10051]=3519,[10052]=3519,[10053]=3483,
    [10054]=3483,[10055]=3483,[10056]=3483,[10057]=3483,[10058]=3483,[10059]=3483,[10060]=3483,[10061]=3483,
    [10062]=3483,[10063]=3525,[10064]=3525,[10065]=3525,[10066]=3525,[10067]=3525,[10068]=3430,[10069]=3430,
    [10070]=3430,[10071]=3430,[10072]=3430,[10073]=3430,[10074]=3518,[10075]=3518,[10076]=3518,[10077]=3518,
    [10078]=3483,[10079]=3483,[10081]=3518,[10082]=3518,[10084]=3483,[10085]=3518,[10086]=3483,[10087]=3483,
    [10088]=3483,[10089]=3483,[10090]=3483,[10091]=3688,[10092]=3483,[10093]=3483,[10094]=3688,[10095]=3688,
    [10096]=3521,[10097]=3688,[10098]=3688,[10099]=3483,[10100]=3483,[10101]=3518,[10102]=3518,[10103]=3483,
    [10104]=3521,[10105]=3521,[10106]=3483,[10107]=3518,[10108]=3518,[10109]=3518,[10110]=3483,[10111]=3518,
    [10112]=3519,[10113]=3518,[10114]=3518,[10115]=3521,[10116]=3521,[10117]=3521,[10118]=3521,[10119]=3483,
    [10120]=3483,[10121]=3483,[10122]=3483,[10123]=3483,[10124]=3483,[10125]=3483,[10126]=3483,[10127]=3483,
    [10128]=3483,[10129]=3483,[10130]=3483,[10131]=3483,[10132]=3483,[10133]=3483,[10134]=3483,[10135]=3483,
    [10136]=3483,[10137]=3483,[10138]=3483,[10139]=3483,[10140]=3483,[10141]=3483,[10142]=3483,[10143]=3483,
    [10144]=3483,[10145]=3483,[10146]=3483,[10147]=3483,[10148]=3483,[10149]=3483,[10150]=3483,[10151]=3483,
    [10152]=3483,[10153]=3483,[10154]=3483,[10155]=3483,[10156]=3483,[10157]=3483,[10158]=3483,[10159]=3483,
    [10160]=3483,[10161]=3483,[10162]=3483,[10163]=3483,[10164]=3790,[10165]=3792,[10166]=3430,[10167]=3790,
    [10168]=3518,[10169]=3703,[10170]=3518,[10171]=3518,[10172]=3518,[10173]=3523,[10174]=3523,[10175]=3518,
    [10176]=3523,[10177]=3688,[10178]=3688,[10179]=3523,[10180]=3519,[10182]=3523,[10183]=3523,[10184]=3523,
    [10185]=3523,[10186]=3523,[10187]=3523,[10188]=3523,[10189]=3523,[10190]=3523,[10191]=3523,[10192]=3523,
    [10193]=3523,[10194]=3523,[10195]=3519,[10196]=3519,[10197]=3523,[10198]=3523,[10199]=3523,[10200]=3523,
    [10201]=3519,[10202]=3523,[10203]=3523,[10204]=3523,[10205]=3523,[10206]=3523,[10207]=3483,[10208]=3483,
    [10209]=3523,[10210]=3519,[10211]=3703,[10212]=3518,[10213]=3483,[10214]=3483,[10216]=3792,[10218]=3792,
    [10220]=3483,[10221]=3523,[10222]=3523,[10223]=3523,[10224]=3523,[10225]=3523,[10226]=3523,[10227]=3688,
    [10228]=3688,[10229]=3483,[10230]=3483,[10231]=3703,[10232]=3523,[10233]=3523,[10234]=3523,[10235]=3523,
    [10236]=3483,[10237]=3523,[10238]=3483,[10239]=3523,[10240]=3523,[10241]=3523,[10242]=3483,[10243]=3523,
    [10244]=3523,[10245]=3523,[10246]=3523,[10247]=3523,[10248]=3523,[10249]=3523,[10250]=3483,[10251]=3518,
    [10252]=3518,[10253]=3688,[10254]=3483,[10255]=3483,[10256]=3523,[10257]=3523,[10258]=3483,[10259]=4,[10260]=3523,
    [10261]=3523,[10262]=3523,[10263]=3523,[10264]=3523,[10265]=3523,[10266]=3523,[10267]=3523,[10268]=3523,
    [10269]=3523,[10270]=3523,[10271]=3523,[10272]=3523,[10273]=3523,[10274]=3523,[10275]=3523,[10276]=3523,
    [10277]=1941,[10278]=3483,[10279]=1941,[10280]=3703,[10281]=3523,[10282]=1941,[10283]=1941,[10284]=1941,
    [10285]=1941,[10286]=3483,[10287]=3483,[10288]=3483,[10289]=3483,[10290]=3523,[10291]=3483,[10292]=3523,
    [10293]=3523,[10294]=3483,[10295]=3483,[10296]=1941,[10297]=1941,[10298]=1941,[10299]=3523,[10300]=3523,
    [10301]=3523,[10302]=3524,[10303]=3524,[10304]=3524,[10305]=3523,[10306]=3523,[10307]=3523,[10308]=3523,
    [10309]=3523,[10310]=3523,[10311]=3523,[10312]=3523,[10313]=3523,[10314]=3523,[10315]=3523,[10316]=3523,
    [10317]=3523,[10318]=3523,[10319]=3523,[10320]=3523,[10321]=3523,[10322]=3523,[10323]=3523,[10324]=3524,
    [10325]=3703,[10326]=3703,[10327]=3703,[10328]=3523,[10329]=3523,[10330]=3523,[10331]=3523,[10332]=3523,
    [10333]=3523,[10334]=3523,[10335]=3523,[10336]=3523,[10337]=3523,[10338]=3523,[10339]=3523,[10340]=3483,
    [10341]=3523,[10342]=3523,[10343]=3523,[10344]=3483,[10345]=3523,[10346]=3483,[10347]=3483,[10348]=3523,
    [10350]=3483,[10351]=3483,[10352]=1657,[10353]=3523,[10354]=1657,[10355]=3521,[10356]=3557,[10357]=3557,
    [10358]=3557,[10359]=3487,[10360]=3487,[10361]=3487,[10362]=3487,[10364]=3487,[10366]=3523,[10367]=3483,
    [10368]=3483,[10369]=3483,[10372]=3483,[10373]=3557,[10374]=28,[10379]=3518,[10380]=3523,[10381]=3523,
    [10382]=3483,[10384]=3523,[10385]=3523,[10388]=3483,[10389]=3483,[10390]=3483,[10391]=3483,[10392]=3483,
    [10393]=3483,[10394]=3483,[10395]=3483,[10396]=3483,[10397]=3483,[10398]=3483,[10399]=3483,[10400]=3483,
    [10401]=3483,[10403]=3483,[10404]=3523,[10405]=3523,[10406]=3523,[10407]=3523,[10408]=3523,[10409]=3523,
    [10410]=3523,[10411]=3523,[10412]=3703,[10413]=3523,[10414]=3703,[10415]=3703,[10416]=3703,[10417]=3523,
    [10418]=3523,[10419]=3703,[10420]=3703,[10421]=3703,[10422]=3523,[10423]=3523,[10424]=3523,[10425]=3523,
    [10426]=3523,[10427]=3523,[10428]=3524,[10429]=3523,[10430]=3523,[10431]=3523,[10432]=3523,[10433]=3523,
    [10434]=3523,[10435]=3523,[10436]=3523,[10437]=3523,[10438]=3523,[10439]=3523,[10440]=3523,[10441]=3523,
    [10442]=3483,[10443]=3483,[10444]=3519,[10445]=1941,[10446]=3519,[10447]=3519,[10448]=3519,[10449]=3483,
    [10450]=3483,[10451]=3520,[10455]=3522,[10456]=3522,[10457]=3522,[10458]=3520,[10459]=3607,[10460]=1941,
    [10461]=1941,[10462]=1941,[10463]=1941,[10464]=1941,[10465]=1941,[10466]=1941,[10467]=1941,[10468]=1941,
    [10469]=1941,[10470]=1941,[10471]=1941,[10472]=1941,[10473]=1941,[10474]=1941,[10475]=1941,[10476]=3518,
    [10477]=3518,[10478]=3518,[10479]=3518,[10480]=3520,[10481]=3520,[10482]=3483,[10483]=3483,[10484]=3483,
    [10485]=3483,[10486]=3522,[10487]=3522,[10488]=3522,[10491]=3522,[10492]=1537,[10493]=1637,[10494]=1537,
    [10495]=1637,[10496]=1537,[10497]=1637,[10498]=1537,[10501]=1637,[10502]=3522,[10503]=3522,[10504]=3522,
    [10505]=3522,[10506]=3522,[10507]=3523,[10508]=3523,[10509]=3703,[10510]=3522,[10511]=3522,[10512]=3522,
    [10513]=3520,[10514]=3520,[10515]=3520,[10516]=3522,[10517]=3522,[10518]=3522,[10519]=3520,[10520]=3557,
    [10521]=3520,[10522]=3520,[10523]=3520,[10524]=3522,[10525]=3522,[10526]=3522,[10527]=3520,[10530]=3520,
    [10531]=3358,[10534]=3358,[10535]=3358,[10537]=3520,[10539]=3483,[10540]=3520,[10541]=3520,[10542]=3522,
    [10543]=3522,[10544]=3522,[10545]=3522,[10546]=3520,[10548]=3520,[10550]=3520,[10551]=3703,[10552]=3703,
    [10553]=3703,[10554]=3703,[10555]=3522,[10556]=3522,[10557]=3522,[10558]=3535,[10559]=3535,[10560]=3845,
    [10561]=1941,[10562]=3520,[10563]=3520,[10564]=3520,[10565]=3522,[10566]=3522,[10567]=3522,[10568]=3520,
    [10569]=3520,[10570]=3520,[10571]=3520,[10572]=3520,[10573]=3520,[10574]=3520,[10575]=3520,[10576]=3520,
    [10577]=3520,[10578]=3520,[10579]=3520,[10580]=3522,[10581]=3522,[10582]=3520,[10583]=3520,[10584]=3522,
    [10585]=3520,[10586]=3520,[10587]=3520,[10588]=3520,[10593]=3520,[10594]=3522,[10595]=3520,[10596]=3520,
    [10597]=3520,[10598]=3520,[10599]=3520,[10600]=3520,[10601]=3520,[10602]=3520,[10603]=3520,[10605]=3520,
    [10606]=3520,[10607]=3522,[10608]=3522,[10609]=3522,[10611]=3520,[10612]=3520,[10613]=3520,[10614]=3522,
    [10615]=3522,[10617]=3522,[10618]=3522,[10619]=3520,[10620]=3522,[10621]=3520,[10622]=3520,[10623]=3520,
    [10624]=3520,[10625]=3520,[10626]=3520,[10627]=3520,[10628]=3520,[10629]=3483,[10630]=3483,[10632]=3522,
    [10633]=3520,[10634]=3520,[10635]=3520,[10636]=3520,[10638]=3520,[10639]=3520,[10640]=3518,[10641]=3518,
    [10642]=3520,[10643]=3520,[10644]=3520,[10645]=3520,[10646]=3518,[10647]=3520,[10648]=3520,[10649]=3688,
    [10650]=3520,[10651]=3520,[10652]=3523,[10653]=3703,[10654]=3703,[10655]=3703,[10656]=3703,[10657]=3522,
    [10658]=3703,[10659]=3703,[10660]=3520,[10661]=3520,[10662]=3520,[10663]=3520,[10664]=3520,[10665]=3520,
    [10666]=3520,[10667]=3520,[10668]=3518,[10669]=3518,[10670]=3520,[10671]=3522,[10672]=3520,[10673]=3520,
    [10674]=3522,[10675]=3522,[10676]=3520,[10677]=3520,[10678]=3520,[10679]=3520,[10680]=3520,[10681]=3520,
    [10682]=3522,[10683]=3520,[10684]=3520,[10685]=3520,[10686]=3520,[10687]=3520,[10688]=3520,[10689]=3518,
    [10690]=3522,[10691]=3520,[10700]=3520,[10701]=3523,[10702]=3520,[10703]=3520,[10704]=3845,[10705]=3845,
    [10706]=3520,[10707]=3520,[10708]=3520,[10709]=3522,[10710]=3522,[10711]=3522,[10712]=3522,[10713]=3522,
    [10714]=3522,[10715]=3522,[10716]=3522,[10717]=3522,[10718]=3522,[10719]=3522,[10720]=3522,[10721]=3522,
    [10722]=3522,[10723]=3522,[10724]=3522,[10725]=3457,[10726]=3457,[10727]=3457,[10728]=3457,[10729]=3457,
    [10730]=3457,[10731]=3457,[10732]=3457,[10733]=3457,[10734]=3457,[10735]=3457,[10736]=3457,[10737]=1941,
    [10738]=3457,[10739]=3457,[10740]=3457,[10741]=3457,[10742]=3522,[10744]=3520,[10745]=3520,[10747]=3522,
    [10748]=3522,[10749]=3522,[10750]=3520,[10751]=3520,[10752]=331,[10753]=3522,[10754]=3483,[10755]=3483,
    [10756]=3483,[10757]=3483,[10758]=3483,[10759]=3520,[10760]=3520,[10761]=3520,[10762]=3483,[10763]=3483,
    [10764]=3483,[10765]=3520,[10766]=3520,[10767]=3520,[10768]=3520,[10769]=3520,[10770]=3522,[10771]=3522,
    [10772]=3520,[10773]=3520,[10774]=3520,[10775]=3520,[10776]=3520,[10777]=3520,[10779]=3520,[10780]=3520,
    [10781]=3520,[10782]=3520,[10783]=3522,[10784]=3522,[10785]=3522,[10790]=3522,[10791]=3519,[10792]=3483,
    [10794]=3520,[10795]=3522,[10796]=3522,[10797]=3522,[10798]=3522,[10799]=3522,[10800]=3522,[10801]=3522,
    [10802]=3522,[10803]=3522,[10804]=3520,[10805]=3522,[10806]=3522,[10807]=3520,[10808]=3520,[10809]=3483,
    [10810]=3522,[10811]=3520,[10812]=3522,[10813]=3483,[10814]=3520,[10815]=3520,[10816]=3520,[10817]=3520,
    [10818]=3522,[10819]=3522,[10820]=3522,[10821]=3522,[10822]=3703,[10823]=3520,[10824]=3520,[10825]=3522,
    [10826]=3703,[10827]=3703,[10828]=3703,[10829]=3522,[10833]=3522,[10834]=3483,[10835]=3483,[10836]=3520,
    [10837]=3520,[10838]=3483,[10839]=3519,[10840]=3519,[10841]=3519,[10842]=3519,[10843]=3522,[10844]=3522,
    [10845]=3522,[10846]=3522,[10847]=3519,[10848]=3519,[10849]=3519,[10850]=3523,[10851]=3522,[10852]=3519,
    [10853]=3522,[10854]=3520,[10855]=3523,[10856]=3523,[10857]=3523,[10858]=3520,[10859]=3522,[10860]=3522,
    [10861]=3519,[10862]=3519,[10863]=3519,[10864]=3483,[10865]=3522,[10866]=3520,[10867]=3522,[10868]=3519,
    [10869]=3519,[10870]=3520,[10871]=3520,[10872]=3520,[10873]=3519,[10874]=3519,[10875]=3483,[10876]=3483,
    [10877]=3519,[10878]=3519,[10879]=3519,[10880]=3519,[10881]=3519,[10882]=3845,[10883]=3703,[10884]=3703,
    [10885]=3703,[10886]=3703,[10887]=3519,[10888]=3836,[10892]=3519,[10893]=3522,[10894]=3522,[10895]=3483,
    [10897]=3519,[10899]=3519,[10900]=3717,[10902]=3717,[10903]=3483,[10907]=3522,[10908]=3519,[10909]=3483,
    [10910]=3522,[10911]=3522,[10912]=3522,[10913]=3519,[10914]=3519,[10915]=3519,[10916]=3483,[10917]=3519,
    [10918]=3519,[10919]=3483,[10920]=3519,[10921]=3519,[10922]=3519,[10923]=3519,[10924]=3523,[10925]=3519,
    [10926]=3519,[10927]=3522,[10928]=3522,[10929]=3519,[10934]=3519,[10935]=3483,[10936]=3483,[10943]=3483,
    [10945]=3520,[10946]=3845,[10947]=3606,[10948]=3703,[10956]=3520,[10957]=3959,[10958]=3959,[10968]=3959,
    [10969]=3523,[10970]=3523,[10971]=3523,[10972]=3523,[10973]=3523,[10974]=3522,[10975]=3522,[10976]=3522,
    [10980]=3792,[10981]=3792,[10982]=3522,[10983]=3522,[10984]=3703,[10988]=3520,[10994]=3522,[10995]=3522,
    [10996]=3522,[10997]=3522,[10998]=3522,[11001]=3522,[11002]=3483,[11003]=3483,[11004]=3679,[11005]=3679,
    [11006]=3679,[11007]=3845,[11008]=3679,[11009]=3522,[11011]=3522,[11012]=3520,[11013]=3520,[11014]=3520,
    [11015]=3520,[11016]=3520,[11017]=3520,[11018]=3520,[11019]=3520,[11020]=3520,[11021]=3679,[11022]=3522,
    [11023]=3522,[11024]=3703,[11025]=3522,[11026]=3522,[11027]=3522,[11028]=3679,[11029]=3679,[11030]=3522,
    [11031]=3457,[11032]=3457,[11033]=3457,[11034]=3457,[11035]=3520,[11036]=3522,[11037]=3518,[11038]=3703,
    [11039]=3703,[11040]=3522,[11041]=3520,[11042]=3518,[11043]=3522,[11044]=3518,[11045]=3703,[11046]=3703,
    [11047]=3522,[11048]=3518,[11049]=3520,[11050]=3520,[11051]=3522,[11052]=3520,[11053]=3520,[11054]=3520,
    [11055]=3520,[11056]=3679,[11057]=3522,[11058]=3522,[11059]=3522,[11060]=3522,[11061]=3522,[11062]=3522,
    [11063]=3520,[11064]=3520,[11065]=3522,[11066]=3522,[11067]=3520,[11068]=3520,[11069]=3520,[11070]=3520,
    [11071]=3520,[11072]=3679,[11073]=3679,[11074]=3519,[11075]=3520,[11076]=3520,[11077]=3520,[11078]=3522,
    [11079]=3522,[11080]=3522,[11081]=3520,[11082]=3520,[11083]=3520,[11084]=3520,[11085]=3679,[11086]=3520,
    [11089]=3520,[11090]=3520,[11091]=3522,[11092]=3520,[11093]=3679,[11094]=3520,[11095]=3520,[11096]=3703,
    [11097]=3520,[11098]=3679,[11099]=3520,[11100]=3520,[11101]=3520,[11102]=3522,[11103]=1941,[11104]=1941,
    [11105]=1941,[11106]=1941,[11107]=3520,[11108]=3520,[11109]=3703,[11110]=3703,[11111]=3703,[11112]=3703,
    [11113]=3703,[11114]=3703,[11118]=3836,[11122]=3522,[11123]=15,[11124]=15,[11126]=15,[11128]=15,[11129]=215,
    [11131]=3805,[11132]=3805,[11133]=15,[11135]=15,[11136]=15,[11137]=15,[11138]=15,[11139]=15,[11140]=15,[11141]=15,
    [11142]=15,[11143]=15,[11144]=15,[11145]=15,[11146]=15,[11147]=15,[11148]=15,[11149]=15,[11150]=15,[11151]=15,
    [11152]=15,[11153]=495,[11154]=495,[11155]=495,[11156]=15,[11157]=495,[11158]=15,[11159]=15,[11160]=15,[11161]=15,
    [11162]=15,[11163]=3433,[11164]=3805,[11165]=3805,[11166]=3805,[11167]=495,[11168]=495,[11169]=15,[11170]=495,
    [11171]=3805,[11172]=15,[11173]=15,[11174]=15,[11175]=495,[11176]=495,[11177]=15,[11178]=3805,[11179]=495,
    [11180]=15,[11181]=15,[11182]=495,[11183]=15,[11184]=15,[11185]=15,[11186]=15,[11187]=495,[11188]=495,[11189]=495,
    [11190]=495,[11191]=15,[11192]=15,[11193]=15,[11194]=15,[11195]=3805,[11196]=3805,[11198]=15,[11199]=495,
    [11200]=15,[11201]=15,[11202]=495,[11203]=15,[11204]=15,[11205]=15,[11206]=15,[11207]=15,[11208]=15,[11209]=15,
    [11210]=15,[11211]=15,[11212]=15,[11213]=15,[11214]=15,[11215]=15,[11216]=3457,[11217]=15,[11220]=495,[11221]=495,
    [11222]=15,[11223]=15,[11224]=495,[11225]=15,[11227]=495,[11228]=495,[11229]=495,[11230]=495,[11231]=495,
    [11232]=495,[11233]=495,[11234]=495,[11235]=495,[11236]=495,[11237]=495,[11238]=495,[11239]=495,[11240]=495,
    [11242]=495,[11243]=495,[11244]=495,[11245]=495,[11246]=495,[11247]=495,[11248]=495,[11249]=495,[11250]=495,
    [11251]=495,[11252]=206,[11253]=495,[11254]=495,[11255]=495,[11256]=495,[11257]=495,[11258]=495,[11259]=495,
    [11260]=495,[11261]=495,[11262]=206,[11263]=495,[11264]=495,[11265]=495,[11266]=495,[11267]=495,[11268]=495,
    [11269]=495,[11270]=495,[11271]=495,[11272]=206,[11273]=495,[11274]=495,[11275]=495,[11276]=495,[11277]=495,
    [11278]=495,[11279]=495,[11280]=495,[11281]=495,[11282]=495,[11283]=495,[11284]=495,[11285]=495,[11286]=495,
    [11287]=495,[11288]=495,[11289]=495,[11290]=495,[11291]=495,[11294]=495,[11295]=495,[11296]=495,[11297]=495,
    [11298]=495,[11299]=495,[11300]=495,[11301]=495,[11302]=495,[11303]=495,[11304]=495,[11305]=495,[11306]=495,
    [11307]=495,[11308]=495,[11309]=495,[11310]=495,[11311]=495,[11312]=495,[11313]=495,[11314]=495,[11315]=495,
    [11316]=495,[11318]=495,[11321]=495,[11322]=495,[11323]=495,[11324]=495,[11325]=495,[11326]=495,[11327]=495,
    [11328]=495,[11329]=495,[11330]=495,[11331]=495,[11332]=495,[11333]=495,[11335]=3358,[11336]=2597,[11337]=3820,
    [11338]=3277,[11339]=3358,[11340]=2597,[11341]=3820,[11342]=3277,[11343]=495,[11344]=495,[11346]=495,[11348]=495,
    [11349]=495,[11350]=495,[11351]=495,[11352]=495,[11354]=3535,[11357]=495,[11358]=495,[11361]=495,[11362]=3535,
    [11363]=3535,[11364]=3535,[11365]=495,[11366]=495,[11367]=495,[11368]=3607,[11369]=3607,[11370]=3607,[11371]=3607,
    [11372]=3688,[11373]=3688,[11374]=3688,[11375]=3688,[11377]=3688,[11381]=1941,[11382]=1941,[11383]=1941,
    [11384]=3845,[11385]=3845,[11386]=3845,[11387]=3845,[11388]=3845,[11389]=3845,[11390]=495,[11392]=495,[11393]=495,
    [11394]=495,[11395]=495,[11396]=495,[11397]=495,[11398]=495,[11401]=495,[11405]=151,[11409]=495,[11410]=495,
    [11413]=495,[11414]=495,[11415]=495,[11416]=495,[11417]=495,[11419]=495,[11420]=495,[11421]=495,[11422]=495,
    [11423]=495,[11424]=495,[11425]=151,[11426]=495,[11427]=495,[11428]=495,[11429]=495,[11431]=495,[11432]=495,
    [11433]=495,[11434]=495,[11442]=495,[11447]=495,[11450]=495,[11451]=3703,[11452]=495,[11454]=495,[11455]=495,
    [11456]=495,[11457]=495,[11458]=495,[11459]=495,[11460]=495,[11461]=495,[11464]=495,[11465]=495,[11466]=495,
    [11467]=495,[11468]=495,[11469]=495,[11470]=495,[11471]=495,[11472]=495,[11473]=495,[11474]=495,[11475]=495,
    [11476]=495,[11477]=495,[11478]=495,[11479]=495,[11480]=495,[11481]=4080,[11482]=4080,[11483]=495,[11484]=495,
    [11485]=495,[11488]=4131,[11489]=495,[11490]=4131,[11491]=495,[11492]=4131,[11494]=495,[11495]=495,[11496]=4080,
    [11497]=3520,[11498]=3520,[11499]=4131,[11500]=4131,[11501]=495,[11502]=3518,[11503]=3518,[11504]=495,
    [11505]=3519,[11506]=3519,[11507]=495,[11508]=495,[11509]=495,[11510]=495,[11511]=495,[11512]=495,[11513]=3522,
    [11514]=3522,[11515]=3483,[11516]=3483,[11517]=3703,[11519]=495,[11520]=3519,[11521]=3519,[11523]=4080,
    [11524]=4080,[11525]=4080,[11526]=4080,[11528]=495,[11529]=495,[11531]=495,[11532]=4080,[11533]=4080,[11534]=3703,
    [11535]=4080,[11536]=4080,[11537]=4080,[11538]=4080,[11539]=4080,[11540]=4080,[11541]=4080,[11542]=4080,
    [11543]=4080,[11544]=3520,[11545]=4080,[11546]=4080,[11547]=4080,[11548]=4080,[11549]=4080,[11550]=4080,
    [11551]=4080,[11554]=4080,[11555]=4080,[11556]=4080,[11558]=4080,[11559]=3537,[11560]=3537,[11561]=3537,
    [11562]=3537,[11563]=3537,[11564]=3537,[11565]=3537,[11566]=3537,[11567]=495,[11568]=495,[11569]=3537,
    [11570]=3537,[11571]=3537,[11572]=495,[11573]=495,[11574]=3537,[11575]=3537,[11576]=3537,[11578]=15,[11581]=15,
    [11584]=3537,[11585]=3537,[11586]=3537,[11587]=3537,[11590]=3537,[11591]=3537,[11592]=3537,[11593]=3537,
    [11594]=3537,[11595]=3537,[11596]=3537,[11597]=3537,[11598]=3537,[11599]=3537,[11600]=3537,[11601]=3537,
    [11602]=3537,[11603]=3537,[11604]=3537,[11605]=3537,[11606]=3537,[11607]=3537,[11608]=3537,[11609]=3537,
    [11610]=3537,[11611]=3537,[11612]=3537,[11613]=3537,[11614]=3537,[11615]=3537,[11616]=3537,[11617]=3537,
    [11618]=3537,[11619]=3537,[11620]=3537,[11621]=3537,[11622]=3537,[11623]=3537,[11624]=3537,[11625]=3537,
    [11626]=3537,[11627]=3537,[11628]=3537,[11629]=3537,[11630]=3537,[11631]=3537,[11632]=3537,[11633]=3537,
    [11634]=3537,[11635]=3537,[11636]=3537,[11637]=3537,[11638]=3537,[11639]=3537,[11640]=3537,[11641]=3537,
    [11642]=3537,[11643]=3537,[11644]=3537,[11645]=3537,[11646]=3537,[11647]=3537,[11648]=3537,[11649]=3537,
    [11650]=3537,[11651]=3537,[11652]=3537,[11653]=3537,[11654]=3537,[11655]=3537,[11657]=3537,[11658]=3537,
    [11659]=3537,[11660]=3537,[11661]=3537,[11662]=3537,[11663]=3537,[11669]=3537,[11670]=3537,[11671]=3537,
    [11672]=3537,[11673]=3537,[11674]=3537,[11675]=3537,[11676]=3537,[11677]=3537,[11678]=3537,[11679]=3537,
    [11680]=3537,[11681]=3537,[11682]=3537,[11683]=3537,[11684]=3537,[11685]=3537,[11686]=3537,[11687]=3537,
    [11688]=3537,[11689]=3537,[11691]=3537,[11692]=3537,[11693]=3537,[11694]=3537,[11696]=3537,[11697]=3537,
    [11698]=3537,[11699]=3537,[11700]=3537,[11701]=3537,[11702]=3537,[11703]=3537,[11704]=3537,[11705]=3537,
    [11706]=3537,[11707]=3537,[11708]=3537,[11709]=3537,[11710]=3537,[11711]=3537,[11712]=3537,[11713]=3537,
    [11714]=3537,[11715]=3537,[11716]=3537,[11717]=3537,[11718]=3537,[11719]=3537,[11720]=3537,[11721]=3537,
    [11722]=3537,[11723]=3537,[11724]=3537,[11725]=3537,[11726]=3537,[11727]=3537,[11728]=3537,[11729]=3537,
    [11732]=3537,[11787]=3537,[11788]=3537,[11789]=3537,[11790]=3537,[11791]=3537,[11792]=3537,[11793]=3537,
    [11794]=3537,[11795]=3537,[11796]=3537,[11797]=3537,[11863]=3537,[11864]=3537,[11865]=3537,[11866]=3537,
    [11867]=3537,[11868]=3537,[11869]=3537,[11870]=3537,[11871]=3537,[11872]=3537,[11873]=3537,[11875]=3703,
    [11876]=3537,[11877]=3523,[11878]=3537,[11879]=3537,[11880]=3518,[11883]=3537,[11884]=3537,[11886]=3679,
    [11887]=3537,[11888]=3537,[11889]=3537,[11891]=3537,[11892]=3537,[11893]=3537,[11894]=3537,[11895]=3537,
    [11896]=3537,[11897]=3537,[11898]=3537,[11899]=3537,[11900]=3537,[11901]=3537,[11902]=3537,[11903]=3537,
    [11904]=3537,[11905]=4120,[11906]=3537,[11907]=3537,[11908]=3537,[11909]=3537,[11910]=3537,[11911]=4120,
    [11912]=3537,[11913]=3537,[11915]=3537,[11917]=3537,[11918]=3537,[11919]=3537,[11926]=3537,[11927]=3537,
    [11928]=3537,[11929]=3537,[11930]=3537,[11931]=3537,[11935]=3537,[11936]=3537,[11938]=3537,[11939]=3537,
    [11940]=3537,[11941]=3537,[11942]=3537,[11943]=3537,[11944]=3537,[11945]=3537,[11948]=3537,[11949]=3537,
    [11950]=3537,[11955]=3537,[11956]=3537,[11957]=3537,[11958]=65,[11959]=65,[11960]=65,[11961]=3537,[11962]=3537,
    [11964]=3537,[11966]=3537,[11967]=3537,[11968]=3537,[11972]=3537,[11976]=4120,[11977]=65,[11978]=65,[11979]=65,
    [11980]=65,[11981]=394,[11982]=394,[11983]=65,[11984]=394,[11985]=394,[11986]=394,[11988]=394,[11989]=394,
    [11990]=394,[11991]=394,[11993]=394,[11995]=65,[11996]=65,[11997]=394,[11998]=394,[11999]=65,[12000]=65,
    [12002]=394,[12003]=394,[12004]=65,[12005]=65,[12006]=65,[12007]=394,[12008]=65,[12009]=65,[12010]=394,[12012]=65,
    [12013]=65,[12014]=394,[12015]=65,[12016]=65,[12017]=65,[12020]=3537,[12022]=65,[12026]=394,[12027]=394,
    [12028]=65,[12029]=394,[12030]=65,[12031]=65,[12032]=65,[12033]=65,[12034]=65,[12035]=3537,[12036]=65,
    [12037]=4196,[12038]=394,[12039]=65,[12040]=65,[12041]=65,[12042]=394,[12043]=65,[12044]=65,[12045]=65,[12046]=65,
    [12047]=65,[12048]=65,[12049]=65,[12050]=65,[12051]=65,[12052]=65,[12053]=65,[12054]=394,[12055]=65,[12056]=65,
    [12057]=65,[12058]=394,[12059]=65,[12060]=65,[12062]=65,[12063]=65,[12064]=65,[12065]=65,[12066]=65,[12067]=65,
    [12068]=394,[12069]=65,[12070]=394,[12071]=65,[12072]=65,[12073]=394,[12074]=394,[12075]=65,[12076]=65,[12077]=65,
    [12078]=65,[12079]=65,[12080]=65,[12081]=394,[12082]=394,[12083]=65,[12084]=65,[12085]=65,[12086]=3537,
    [12087]=3537,[12088]=3537,[12089]=65,[12090]=65,[12091]=65,[12092]=65,[12093]=394,[12094]=394,[12095]=65,
    [12096]=65,[12097]=65,[12098]=65,[12099]=394,[12100]=65,[12101]=65,[12102]=65,[12104]=65,[12105]=394,[12106]=65,
    [12107]=65,[12108]=3537,[12109]=394,[12110]=65,[12111]=65,[12112]=65,[12113]=394,[12114]=394,[12115]=65,
    [12116]=394,[12117]=65,[12118]=65,[12119]=65,[12120]=394,[12121]=394,[12122]=65,[12123]=65,[12124]=65,[12125]=65,
    [12126]=65,[12127]=65,[12128]=394,[12129]=394,[12130]=394,[12131]=394,[12133]=65,[12135]=394,[12136]=65,
    [12137]=394,[12139]=394,[12140]=65,[12141]=3537,[12142]=65,[12143]=65,[12144]=65,[12145]=65,[12146]=65,[12147]=65,
    [12148]=65,[12149]=65,[12150]=65,[12151]=65,[12152]=394,[12153]=394,[12155]=394,[12156]=3537,[12157]=65,
    [12158]=394,[12159]=394,[12160]=394,[12161]=394,[12162]=394,[12163]=394,[12164]=394,[12165]=394,[12166]=65,
    [12167]=65,[12168]=65,[12169]=65,[12170]=394,[12173]=65,[12174]=65,[12175]=394,[12176]=394,[12177]=394,
    [12179]=394,[12180]=394,[12181]=495,[12182]=65,[12183]=394,[12184]=394,[12185]=394,[12188]=65,[12189]=65,
    [12194]=394,[12195]=394,[12196]=394,[12197]=394,[12198]=394,[12199]=394,[12200]=65,[12201]=394,[12202]=394,
    [12203]=394,[12204]=394,[12205]=65,[12206]=65,[12207]=394,[12208]=394,[12209]=65,[12210]=394,[12211]=65,
    [12212]=394,[12213]=394,[12214]=65,[12215]=394,[12216]=394,[12217]=394,[12218]=65,[12219]=394,[12220]=394,
    [12221]=65,[12222]=394,[12223]=394,[12224]=65,[12225]=394,[12226]=394,[12227]=394,[12229]=394,[12230]=65,
    [12231]=394,[12232]=65,[12233]=394,[12234]=65,[12235]=65,[12236]=394,[12237]=65,[12238]=4196,[12239]=65,
    [12240]=65,[12241]=394,[12242]=394,[12243]=65,[12244]=394,[12245]=65,[12246]=394,[12247]=394,[12248]=394,
    [12249]=394,[12250]=394,[12251]=65,[12252]=65,[12253]=65,[12254]=65,[12255]=394,[12256]=394,[12257]=394,
    [12258]=65,[12259]=394,[12260]=65,[12261]=65,[12262]=65,[12263]=65,[12264]=65,[12265]=65,[12266]=65,[12267]=65,
    [12268]=394,[12269]=65,[12270]=394,[12271]=65,[12272]=65,[12273]=65,[12274]=65,[12275]=65,[12276]=65,[12278]=65,
    [12279]=394,[12280]=394,[12281]=65,[12282]=65,[12283]=65,[12284]=394,[12286]=65,[12287]=65,[12288]=394,
    [12289]=394,[12290]=65,[12291]=65,[12292]=394,[12293]=394,[12294]=394,[12295]=394,[12296]=394,[12297]=65,
    [12298]=65,[12299]=394,[12300]=394,[12301]=65,[12302]=394,[12303]=65,[12304]=65,[12306]=65,[12307]=394,
    [12308]=394,[12309]=65,[12310]=394,[12311]=65,[12313]=65,[12314]=394,[12315]=394,[12316]=394,[12318]=394,
    [12319]=65,[12320]=65,[12321]=65,[12323]=394,[12324]=394,[12325]=65,[12326]=65,[12327]=394,[12328]=394,
    [12329]=394,[12371]=394,[12410]=65,[12411]=394,[12412]=394,[12413]=394,[12414]=394,[12415]=394,[12416]=65,
    [12417]=65,[12418]=65,[12421]=65,[12422]=394,[12423]=394,[12424]=394,[12425]=394,[12426]=394,[12427]=394,
    [12428]=394,[12429]=394,[12430]=394,[12431]=394,[12432]=394,[12433]=394,[12434]=394,[12435]=65,[12436]=394,
    [12437]=394,[12438]=65,[12439]=65,[12440]=65,[12441]=65,[12442]=65,[12443]=394,[12444]=394,[12446]=394,[12447]=65,
    [12448]=65,[12449]=65,[12450]=65,[12451]=394,[12452]=65,[12453]=394,[12454]=65,[12455]=65,[12456]=65,[12457]=65,
    [12458]=65,[12459]=65,[12460]=65,[12461]=65,[12462]=65,[12463]=65,[12464]=65,[12465]=65,[12466]=65,[12467]=65,
    [12468]=394,[12469]=65,[12470]=65,[12471]=3537,[12472]=65,[12473]=65,[12474]=65,[12475]=65,[12476]=65,[12477]=65,
    [12478]=65,[12479]=3703,[12480]=3703,[12481]=495,[12482]=495,[12483]=394,[12484]=394,[12486]=3537,[12487]=394,
    [12488]=65,[12489]=3711,[12492]=3537,[12493]=3711,[12495]=65,[12496]=65,[12497]=65,[12498]=65,[12499]=65,
    [12500]=65,[12501]=66,[12502]=66,[12503]=66,[12504]=66,[12505]=66,[12506]=66,[12507]=66,[12508]=66,[12509]=66,
    [12510]=66,[12511]=394,[12512]=66,[12513]=1941,[12514]=66,[12515]=1941,[12518]=66,[12519]=66,[12520]=3711,
    [12521]=3711,[12522]=3711,[12523]=3711,[12524]=3711,[12525]=3711,[12526]=3711,[12527]=66,[12528]=3711,
    [12529]=3711,[12530]=3711,[12531]=3711,[12532]=3711,[12533]=3711,[12534]=3711,[12535]=3711,[12536]=3711,
    [12537]=3711,[12538]=3711,[12539]=3711,[12540]=3711,[12541]=66,[12542]=65,[12543]=3711,[12544]=3711,[12545]=65,
    [12546]=3711,[12547]=490,[12548]=3711,[12549]=3711,[12550]=3711,[12551]=3711,[12552]=66,[12553]=66,[12554]=66,
    [12555]=66,[12556]=3711,[12557]=66,[12558]=3711,[12559]=3711,[12560]=3711,[12561]=3711,[12562]=66,[12563]=66,
    [12564]=66,[12565]=66,[12566]=495,[12567]=66,[12568]=66,[12569]=3711,[12570]=3711,[12571]=3711,[12572]=3711,
    [12573]=3711,[12574]=3711,[12575]=3711,[12576]=3711,[12577]=3711,[12578]=3711,[12579]=3711,[12580]=3711,
    [12581]=3711,[12582]=3711,[12583]=66,[12584]=66,[12585]=66,[12586]=3711,[12587]=66,[12588]=66,[12589]=3711,
    [12590]=66,[12591]=66,[12593]=3711,[12594]=66,[12595]=3711,[12596]=66,[12597]=66,[12598]=66,[12599]=66,[12601]=66,
    [12602]=66,[12603]=3711,[12604]=66,[12605]=3711,[12606]=66,[12607]=3711,[12608]=3711,[12609]=66,[12610]=66,
    [12611]=3711,[12612]=3711,[12613]=3711,[12614]=3711,[12615]=66,[12616]=3457,[12617]=3711,[12619]=66,[12620]=3711,
    [12621]=3711,[12622]=66,[12623]=66,[12625]=3711,[12627]=66,[12628]=66,[12629]=66,[12630]=66,[12631]=66,[12632]=66,
    [12633]=66,[12634]=3711,[12636]=66,[12637]=66,[12638]=66,[12639]=66,[12641]=66,[12642]=66,[12643]=66,[12644]=3711,
    [12645]=3711,[12646]=66,[12647]=66,[12648]=66,[12649]=66,[12650]=66,[12651]=3711,[12652]=66,[12653]=66,
    [12654]=3711,[12655]=66,[12657]=66,[12658]=3711,[12659]=66,[12660]=3711,[12661]=66,[12662]=66,[12663]=66,
    [12664]=66,[12665]=66,[12666]=66,[12667]=66,[12668]=66,[12670]=66,[12671]=3711,[12672]=66,[12673]=66,[12674]=66,
    [12675]=66,[12676]=66,[12680]=66,[12681]=3711,[12682]=3711,[12683]=3711,[12684]=66,[12685]=66,[12687]=66,
    [12688]=3711,[12689]=3711,[12690]=66,[12691]=3711,[12692]=3711,[12695]=3711,[12698]=3711,[12701]=3711,
    [12702]=3711,[12703]=3711,[12704]=3711,[12706]=3711,[12707]=66,[12708]=66,[12709]=66,[12711]=66,[12712]=66,
    [12720]=66,[12725]=66,[12727]=3711,[12728]=3537,[12729]=66,[12730]=66,[12733]=3711,[12734]=3711,[12735]=3711,
    [12736]=3711,[12739]=3711,[12740]=66,[12757]=3711,[12758]=3711,[12759]=3711,[12760]=3711,[12761]=3711,
    [12762]=3711,[12763]=394,[12766]=65,[12767]=65,[12768]=65,[12769]=65,[12779]=394,[12780]=66,[12788]=4342,
    [12789]=66,[12790]=4395,[12791]=4395,[12792]=66,[12793]=66,[12794]=4395,[12795]=66,[12796]=4395,[12798]=3711,
    [12801]=66,[12802]=394,[12803]=3711,[12804]=3711,[12805]=3711,[12806]=210,[12809]=210,[12812]=210,[12813]=210,
    [12814]=210,[12817]=210,[12818]=67,[12819]=67,[12820]=67,[12821]=67,[12822]=67,[12823]=67,[12824]=67,[12825]=67,
    [12826]=67,[12827]=67,[12828]=67,[12829]=67,[12830]=67,[12831]=67,[12832]=67,[12833]=67,[12834]=67,[12835]=67,
    [12836]=67,[12837]=67,[12838]=210,[12839]=210,[12840]=210,[12842]=67,[12843]=67,[12844]=67,[12846]=67,[12850]=210,
    [12851]=67,[12852]=210,[12853]=67,[12854]=67,[12855]=67,[12856]=67,[12857]=66,[12858]=67,[12859]=66,[12860]=67,
    [12861]=66,[12862]=67,[12863]=67,[12864]=67,[12865]=67,[12866]=67,[12867]=67,[12868]=67,[12869]=67,[12870]=67,
    [12871]=67,[12872]=67,[12873]=67,[12874]=67,[12875]=67,[12876]=67,[12877]=67,[12878]=67,[12879]=67,[12880]=67,
    [12881]=67,[12882]=67,[12883]=66,[12884]=66,[12885]=67,[12886]=67,[12887]=210,[12888]=67,[12889]=67,[12890]=67,
    [12891]=210,[12892]=210,[12893]=210,[12894]=66,[12895]=67,[12896]=210,[12897]=210,[12898]=210,[12899]=210,
    [12900]=67,[12901]=66,[12902]=66,[12903]=66,[12904]=66,[12905]=67,[12906]=67,[12907]=67,[12908]=67,[12909]=67,
    [12910]=67,[12911]=3703,[12912]=66,[12913]=67,[12914]=66,[12915]=67,[12916]=66,[12918]=67,[12919]=66,[12920]=67,
    [12921]=67,[12922]=67,[12924]=67,[12925]=67,[12926]=67,[12927]=67,[12928]=67,[12929]=67,[12930]=67,[12931]=67,
    [12932]=66,[12933]=66,[12934]=66,[12935]=66,[12936]=66,[12937]=67,[12938]=210,[12941]=210,[12942]=67,[12947]=210,
    [12948]=66,[12950]=210,[12952]=210,[12953]=67,[12954]=66,[12955]=210,[12956]=67,[12963]=67,[12964]=67,[12965]=67,
    [12966]=67,[12967]=67,[12968]=67,[12969]=67,[12970]=67,[12971]=67,[12972]=67,[12973]=67,[12974]=66,[12975]=67,
    [12976]=67,[12977]=67,[12978]=67,[12979]=67,[12980]=67,[12981]=67,[12982]=210,[12983]=67,[12984]=67,[12985]=67,
    [12986]=67,[12987]=67,[12988]=67,[12990]=67,[12991]=67,[12992]=210,[12993]=67,[12994]=67,[12995]=210,[12996]=67,
    [12997]=67,[12998]=67,[12999]=210,[13000]=67,[13002]=67,[13004]=67,[13005]=67,[13006]=67,[13007]=67,[13008]=210,
    [13009]=67,[13010]=67,[13033]=67,[13034]=67,[13035]=67,[13036]=210,[13037]=67,[13038]=67,[13039]=210,[13041]=210,
    [13042]=210,[13043]=210,[13044]=210,[13045]=210,[13046]=67,[13047]=67,[13048]=67,[13049]=67,[13050]=67,[13051]=67,
    [13052]=3711,[13053]=67,[13054]=67,[13055]=67,[13056]=67,[13057]=67,[13058]=67,[13059]=210,[13060]=67,[13061]=67,
    [13062]=67,[13063]=67,[13067]=67,[13068]=210,[13069]=210,[13070]=210,[13071]=210,[13072]=210,[13073]=210,
    [13074]=210,[13075]=210,[13076]=210,[13077]=210,[13078]=65,[13079]=210,[13080]=210,[13081]=210,[13082]=210,
    [13083]=210,[13084]=210,[13085]=210,[13090]=210,[13091]=210,[13092]=210,[13093]=210,[13094]=4120,[13095]=4120,
    [13096]=4416,[13097]=66,[13098]=4416,[13103]=66,[13104]=210,[13105]=210,[13107]=210,[13108]=4272,[13109]=4272,
    [13110]=210,[13116]=4416,[13117]=210,[13118]=210,[13119]=210,[13120]=210,[13121]=210,[13122]=210,[13124]=4228,
    [13125]=210,[13126]=4228,[13127]=4228,[13128]=4228,[13129]=4196,[13130]=210,[13131]=1196,[13132]=1196,[13133]=210,
    [13134]=210,[13135]=210,[13136]=210,[13137]=210,[13138]=210,[13139]=210,[13140]=210,[13141]=210,[13142]=210,
    [13143]=210,[13144]=210,[13145]=210,[13146]=210,[13148]=210,[13150]=4100,[13151]=4100,[13152]=210,[13153]=4197,
    [13154]=4197,[13155]=210,[13156]=4197,[13157]=210,[13158]=4415,[13159]=4415,[13160]=210,[13161]=210,[13162]=210,
    [13163]=210,[13166]=210,[13167]=4277,[13168]=210,[13169]=210,[13170]=210,[13171]=210,[13173]=210,[13174]=210,
    [13175]=210,[13176]=210,[13177]=4197,[13178]=4197,[13179]=4197,[13180]=4197,[13181]=4197,[13182]=4277,
    [13183]=4197,[13184]=210,[13185]=4197,[13186]=4197,[13189]=4494,[13190]=4494,[13191]=4197,[13192]=4197,
    [13193]=4197,[13194]=4197,[13195]=4197,[13196]=4197,[13197]=4197,[13198]=4197,[13199]=4197,[13200]=4197,
    [13201]=4197,[13203]=4197,[13204]=4494,[13205]=206,[13206]=206,[13207]=4264,[13211]=210,[13212]=210,[13213]=210,
    [13214]=210,[13215]=210,[13216]=210,[13217]=210,[13218]=210,[13219]=210,[13220]=210,[13221]=210,[13222]=4197,
    [13223]=4197,[13224]=210,[13225]=210,[13226]=210,[13227]=210,[13228]=210,[13229]=210,[13230]=210,[13231]=210,
    [13232]=210,[13233]=210,[13234]=210,[13235]=210,[13236]=210,[13237]=210,[13238]=210,[13239]=210,[13240]=4228,
    [13241]=1196,[13242]=65,[13243]=4100,[13244]=4272,[13245]=206,[13246]=4120,[13247]=4228,[13248]=1196,[13249]=4196,
    [13250]=4416,[13251]=4100,[13252]=4264,[13253]=4272,[13254]=4277,[13255]=4494,[13256]=4415,[13257]=3537,
    [13258]=210,[13259]=210,[13260]=210,[13261]=210,[13262]=210,[13263]=210,[13265]=210,[13266]=1637,[13270]=1497,
    [13272]=210,[13273]=67,[13274]=67,[13275]=210,[13276]=210,[13277]=210,[13278]=210,[13279]=210,[13280]=210,
    [13281]=210,[13282]=210,[13283]=210,[13284]=210,[13285]=67,[13286]=210,[13287]=210,[13288]=210,[13289]=210,
    [13290]=210,[13291]=210,[13292]=210,[13293]=210,[13294]=210,[13295]=210,[13296]=210,[13297]=210,[13299]=210,
    [13300]=210,[13301]=210,[13302]=210,[13304]=210,[13305]=210,[13306]=210,[13307]=210,[13308]=210,[13309]=210,
    [13311]=210,[13312]=210,[13313]=210,[13314]=210,[13315]=210,[13316]=210,[13317]=210,[13318]=210,[13319]=210,
    [13320]=210,[13321]=210,[13322]=210,[13327]=210,[13328]=210,[13329]=210,[13330]=210,[13331]=210,[13332]=210,
    [13333]=210,[13334]=210,[13335]=210,[13336]=210,[13337]=210,[13338]=210,[13339]=210,[13340]=210,[13341]=210,
    [13342]=210,[13343]=65,[13344]=210,[13345]=210,[13346]=210,[13347]=65,[13348]=210,[13349]=210,[13350]=210,
    [13351]=210,[13352]=210,[13353]=210,[13354]=210,[13355]=210,[13356]=210,[13357]=210,[13358]=210,[13359]=210,
    [13360]=210,[13361]=210,[13362]=210,[13363]=210,[13364]=210,[13365]=210,[13366]=210,[13367]=210,[13368]=210,
    [13369]=65,[13370]=65,[13371]=65,[13372]=65,[13373]=210,[13374]=210,[13375]=65,[13376]=210,[13377]=65,[13378]=210,
    [13379]=210,[13380]=210,[13381]=210,[13382]=210,[13383]=210,[13384]=4500,[13385]=4500,[13386]=210,[13387]=210,
    [13388]=210,[13389]=210,[13390]=210,[13391]=210,[13392]=210,[13393]=210,[13394]=210,[13395]=210,[13396]=210,
    [13397]=210,[13398]=210,[13399]=210,[13400]=210,[13401]=210,[13402]=210,[13403]=210,[13404]=210,[13405]=4384,
    [13406]=210,[13407]=4384,[13408]=3483,[13409]=3483,[13410]=3483,[13411]=3483,[13412]=3537,[13413]=3537,
    [13414]=3537,[13415]=67,[13416]=67,[13417]=67,[13418]=210,[13419]=210,[13420]=67,[13421]=67,[13422]=67,[13423]=67,
    [13424]=67,[13425]=67,[13426]=67,[13427]=2597,[13428]=2597,[13429]=3520,[13430]=3836,[13431]=3717,[13480]=1941,
    [13481]=210,[13503]=210,[13524]=394,[13538]=4197,[13548]=4197,[13549]=66,[13556]=66,[13603]=67,[13604]=4273,
    [13606]=4273,[13607]=4273,[13609]=4273,[13610]=4273,[13611]=4273,[13616]=4273,[13627]=4273,[13629]=4273,
    [13654]=4273,[13814]=51,[13816]=4273,[13817]=4273,[13818]=4273,[13820]=4273,[13821]=4273,[13822]=4273,
    [13823]=4273,[13839]=4273,[13843]=67,[13847]=4613,[13864]=490,[13887]=490,[13889]=490,[13903]=490,[13904]=490,
    [13905]=490,[13906]=490,[13908]=490,[13914]=490,[13915]=490,[13916]=490,[13966]=490,[13986]=1638,[14030]=151,
    [14077]=12,[14080]=12,[14081]=3430,[14082]=3524,[14083]=1,[14084]=1,[14085]=1657,[14086]=1637,[14087]=215,
    [14088]=14,[14105]=85,[14163]=4710,[14177]=4710,[14178]=3358,[14179]=3820,[14180]=3277,[14181]=3358,[14182]=3820,
    [14183]=3277,[14199]=4723,[14203]=4613,[14349]=139,[14350]=139,[14351]=267,[14352]=722,[14353]=722,[14355]=796,
    [14356]=2437,[14421]=1657,[14436]=215,[14437]=215,[14438]=215,[14439]=215,[14441]=215,[14443]=210,[14444]=210,
    [14488]=4395,[20438]=210,[20439]=210,[24216]=3277,[24217]=3277,[24218]=3277,[24219]=3277,[24220]=3358,
    [24221]=3358,[24223]=3358,[24224]=3277,[24225]=3277,[24226]=3358,[24426]=2597,[24427]=2597,[24428]=1519,
    [24429]=1637,[24442]=4613,[24451]=210,[24454]=210,[24461]=4813,[24476]=210,[24480]=4820,[24498]=4813,[24499]=4809,
    [24500]=4820,[24506]=4809,[24507]=4813,[24510]=4809,[24511]=4809,[24522]=4080,[24541]=4080,[24545]=4812,
    [24547]=4812,[24548]=4812,[24549]=4812,[24553]=4075,[24554]=210,[24555]=210,[24556]=210,[24557]=4395,[24558]=210,
    [24559]=4813,[24560]=210,[24561]=4820,[24562]=4080,[24563]=4080,[24576]=4075,[24579]=4493,[24580]=3456,
    [24581]=3456,[24582]=3456,[24583]=3456,[24584]=4500,[24585]=4273,[24586]=4273,[24587]=4273,[24588]=4273,
    [24589]=4722,[24590]=4812,[24594]=4075,[24595]=4075,[24597]=4075,[24666]=4075,[24682]=4813,[24683]=4813,
    [24710]=4813,[24711]=4820,[24712]=4813,[24713]=4820,[24745]=4812,[24748]=4812,[24749]=4812,[24756]=4812,
    [24793]=4812,[24795]=210,[24796]=210,[24798]=210,[24799]=210,[24800]=210,[24801]=210,[24806]=4820,[24815]=4812,
    [24819]=4812,[24820]=4812,[24821]=4812,[24822]=4812,[24823]=4812,[24825]=4812,[24826]=4812,[24827]=4812,
    [24828]=4812,[24829]=4812,[24830]=4812,[24831]=4812,[24832]=4812,[24833]=4812,[24834]=4812,[24835]=4812,
    [24836]=4812,[24837]=4812,[24838]=4812,[24839]=4812,[24840]=4812,[24841]=4812,[24842]=4812,[24843]=4812,
    [24844]=4812,[24845]=4812,[24846]=4812,[24851]=4812,[24857]=215,[24869]=4812,[24870]=4812,[24871]=4812,
    [24872]=4812,[24873]=4812,[24874]=4812,[24875]=4812,[24876]=4812,[24877]=4812,[24878]=4812,[24879]=4812,
    [24896]=4812,[24912]=4812,[24914]=4812,[24915]=4812,[24916]=4812,[24917]=4812,[24918]=4812,[24923]=4812,[25199]=1,
    [25212]=1,[25229]=1,[25239]=4812,[25240]=4812,[25242]=4812,[25246]=4812,[25247]=4812,[25248]=4812,[25249]=4812,
    [25283]=1,[25285]=1,[25286]=1,[25287]=1,[25289]=1,[25295]=1,[25393]=1,[25444]=14,[25445]=393,[25446]=14,
    [25461]=14,[25470]=14,[25485]=14,[25495]=14,[25500]=1,[26012]=4987,[26013]=4987,[26034]=4987,
}
-- END GENERATED QUESTZONE

-- BEGIN GENERATED QUESTTITLES (tools/questzone_generate.py rewrites everything up to END)
NS.QUEST_TITLE_RU = {
    [1]="Задание Канретада",[2]="Коготь гиппогрифа Острокогтя",[5]="Урчащий живот Трясунчика",
    [6]="Награда за голову Гаррика Тихокрада",[7]="Нападение на лагерь кобольдов",[8]="Выгодная сделка",
    [9]="Поля смерти",[10]="Спасение Холстомера",[11]="Награда за гноллов из стаи Речной Лапы",
    [12]="Народное ополчение",[13]="Народное ополчение",[14]="Народное ополчение",
    [15]="Разведка в руднике Горного эха",[16]="Жажда Джерарда",[17]="В Ульдаман за реактивом",[18]="Братство воров",
    [19]="Тарил'зун",[20]="Угроза Черной горы",[21]="Схватка у рудника Горного эха",
    [22]="Рецепт пирожка из печени жутеклыка",[23]="Лапа Топтыжня",[24]="Голова Тенумбры",[31]="Водный облик",
    [32]="Появление силитидов",[33]="Волки на границе",[34]="Незваный гость",[35]="Новые заботы",
    [36]="Похлебка Западного края",[37]="Пропавшие стражи",[38]="Похлебка Западного края",[39]="Донесение Томаса",
    [40]="Водяная нечисть",[45]="Судьба Рольфа",[46]="Награда за мурлоков",[47]="Золотая пыль",
    [48]="Янтарное сладкое",[49]="Янтарное сладкое",[50]="Янтарное сладкое",[51]="Янтарное сладкое",
    [52]="Защита границы",[53]="Янтарное сладкое",[54]="Донесение в Златоземье",[55]="Морбент Скверн",
    [56]="Ночной Дозор",[57]="Ночной Дозор",[58]="Ночной Дозор",[59]="Броня из кожи и ткани",[60]="Свечи кобольдов",
    [61]="Посылка в Штормград",[63]="Зов воды",[64]="Забытая вещь",[65]="Братство Справедливости",
    [66]="Легенда о Сталване",[67]="Легенда о Сталване",[68]="Легенда о Сталване",[69]="Легенда о Сталване",
    [70]="Легенда о Сталване",[71]="Доклад для Томаса",[72]="Легенда о Сталване",[74]="Легенда о Сталване",
    [75]="Легенда о Сталване",[76]="Яшмовая шахта",[77]="Грязное дело",[78]="Легенда о Сталване",
    [79]="Легенда о Сталване",[80]="Легенда о Сталване",[81]="Груз медовухи",[82]="Исследование Ядовитого улья",
    [83]="Красный лен",[84]="Назад к Билли",[85]="Потерянное ожерелье",[86]="Пирог для Билли",[87]="Фикс",
    [88]="Принцесса должна умереть!",[89]="Мост Безмолвия",[90]="Котлеты из волчатины",[91]="Закон Соломона",
    [92]="Гуляш по-красногорски",[93]="Темные пирожки с крабами",[94]="Недремлющее Око",[96]="Зов воды",
    [97]="Легенда о Сталване",[98]="Легенда о Сталване",[100]="Зов воды",[101]="Тотем кары",
    [102]="Патрулирование Западного Края",[103]="Хранитель пламени",[104]="Опасность на побережье",
    [105]="Увы тебе, Андорал",[106]="Юные влюбленные",[107]="Записка для Вильяма",[109]="Доклад Гриану Камнегриву",
    [110]="Анализ частей насекомых",[111]="Разговор с бабулей",[112]="Хрустальный фукус",
    [113]="Анализ частей насекомых",[114]="Бегство",[115]="Темная магия",[116]="Сухие времена",[117]="Громоварское",
    [118]="Цена подков",[119]="Доставка подков",[120]="Посланец в Штормград",[121]="Гонец в Штормград",
    [122]="Брюшная чешуя",[123]="Вымогатель",[124]="Лай гноллов",[125]="Утраченные инструменты",[126]="Вой в холмах",
    [127]="Продажа рыбы",[128]="Награда за головы орков Черной горы",[129]="Бесплатный обед",[130]="Визит к травнице",
    [131]="Доставка нарциссов",[132]="Братство Справедливости",[133]="Фигурка вурдалака",[134]="Нападение огров",
    [135]="Братство Справедливости",[136]="Спрятанное сокровище капитана Сандерса",
    [138]="Спрятанное сокровище капитана Сандерса",[139]="Спрятанное сокровище капитана Сандерса",
    [140]="Спрятанное сокровище капитана Сандерса",[141]="Братство Справедливости",[142]="Братство Справедливости",
    [143]="Гонец в Западный Край",[144]="Гонец в Западный Край",[145]="Гонец в Темнолесье",[146]="Гонец в Темнолесье",
    [147]="Охота на человека",[148]="Припасы из Темнолесья",[149]="Прядь призрачных волос",[150]="Мурлоки-браконьеры",
    [151]="Бедная старая Савраска",[152]="Зачистка побережья",[153]="Красные кожаные банданы",[154]="Гребень для Евы",
    [155]="Братство Справедливости",[156]="Сбор цветков гнили",[157]="Доставка ниток",[158]="Сок зомби",
    [159]="Доставка сока",[160]="Записка для мэра",[161]="Прямая и черная угроза",[162]="Появление силитидов",
    [163]="Вороний холм",[164]="Припасы для Свена",[165]="Отшельник",[166]="Братство Справедливости",
    [167]="О, брат мой...",[168]="Сбор воспоминаний",[169]="Разыскивается: Гат'Илзогг",[172]="Детская неделя",
    [173]="Воргены в лесу",[174]="Взгляни на звезды",[175]="Взгляни на звезды",[176]="Разыскивается: \"Дробитель\"",
    [177]="Взгляни на звезды",[178]="Поручение Теокрита",[179]="Дворфские экипировщики",
    [180]="Разыскивается: лейтенант Фангор",[181]="Взгляни на звезды",[182]="Пещера троллей",
    [183]="Охотник на вепрей",[184]="Документ Хмуроброва",[185]="Охота на тигров",[186]="Охота на тигров",
    [187]="Охота на тигров",[188]="Охота на тигров",[189]="Уши троллей Кровавого Скальпа",[190]="Охота на пантер",
    [191]="Охота на пантер",[192]="Охота на пантер",[193]="Охота на пантер",[194]="Охота на ящеров",
    [195]="Охота на ящеров",[196]="Охота на ящеров",[197]="Охота на ящеров",[198]="Припасы для рядового Торсена",
    [199]="Прямая и черная угроза",[200]="Букмекер Ирод",[201]="Поиск лагеря",[202]="Полковник Курцен",
    [203]="Второе восстание",[204]="Дурное лекарство",[205]="Тролльское колдовство",[206]="Май'Зот",
    [207]="Тайна Курцена",[208]="Охотник на крупную дичь",[209]="Клыки троллей",[210]="Горшок Кразека",
    [211]="Увы тебе, Андорал",[212]="Холодный обед",[213]="Недружественное поглощение",
    [214]="Красные шелковые банданы",[215]="Тайны джунглей",[216]="Между молотом и Колючим Мехом",
    [217]="Защита королевских земель",[218]="Украденные записи",[220]="Зов воды",[221]="Воргены в лесу",
    [222]="Воргены в лесу",[223]="Воргены в лесу",[224]="Защита королевских земель",[225]="Заброшенная могила",
    [226]="Волки идут по пятам",[227]="Морган Ладимор",[228]="Мор'Ладим",[229]="Выжившая дочь",[230]="Лагерь Свена",
    [231]="Дочерняя любовь",[232]="Посылка для аптекаря Зинг",[233]="Почта Холодной долины",
    [234]="Почта Холодной долины",[235]="Большая охота",[236]="Горючее для разрушителей",
    [237]="Защита королевских земель",[238]="Посылка для аптекаря Зинг",
    [239]="Гарнизон у Западного ручья просит помощи!",[240]="Возвращение к Трясунчику",[243]="Поход в пустыню",
    [244]="Вторжение гноллов",[245]="Восьминогая угроза",[246]="Подсчет врагов",[247]="Завершение охоты",
    [248]="Пронизывающий взор",[249]="Моргант",[250]="Прямая и черная угроза",[251]="Перевод записки Аберкромби",
    [252]="Перевод для Элло",[253]="Невеста Бальзамировщика",[254]="Копание земли",[255]="Наемники",
    [256]="Разыскивается: Чок'сул",[257]="Похвальба охотника",[258]="Вызов охотнику",[261]="По пути Алого ордена",
    [262]="Таинственный незнакомец",[263]="Защита королевских земель",[264]="Покуда смерть не разлучит нас",
    [265]="Продолжение поисков незнакомца",[266]="Расспросы в таверне",[267]="Троггская угроза",
    [268]="Возвращение к Свену",[269]="В поисках мудрости",[270]="Обреченный флот",[272]="Испытание Морского Льва",
    [273]="Снабжение экспедиции",[274]="Прямая и черная угроза",[275]="Нарывы на теле земли",[276]="Вытоптанные луга",
    [277]="Запрет на огонь",[278]="Прямая и черная угроза",[279]="Угроза из глубин",[280]="Прямая и черная угроза",
    [281]="Украденные товары",[282]="Наблюдения Сенира",[283]="Прямая и черная угроза",[284]="Поиски продолжаются",
    [285]="Поиски в поселениях мурлоков",[286]="Возвращение статуэтки",[287]="Форт Мерзлогривов",
    [288]="Третья флотилия",[289]="Проклятая команда",[290]="Очищение",[291]="Донесения",[292]="Око Палета",
    [293]="Проклятое Око",[294]="Месть Ормера",[295]="Месть Ормера",[296]="Месть Ормера",[297]="Сбор идолов",
    [298]="Отчет о ходе раскопок",[299]="Тайны прошлого",[301]="Отчет в Стальгорн",[302]="Порох для Сталекрута",
    [303]="Война с Черным Железом",[304]="Мрачное поручение",[305]="Пропавшие ученые",[306]="Пропавшие ученые",
    [307]="Грязные лапы",[308]="Отвлечь Ярвена",[309]="Охрана груза",[310]="Злейшие соперники",
    [311]="Возвращение к Марлетте",[312]="Ограбление тайника Тундры Макгранна",[313]="Серая берлога",
    [314]="Защита стада",[315]="Всем портерам портер",[317]="Заготовка продовольствия",[318]="\"Вечное сияние\"",
    [319]="Услуга за \"Вечное сияние\"",[320]="Возвращение к Толстопузу",[321]="Светлосталь",[322]="Достойное оружие",
    [323]="Доказательство силы",[324]="Утерянные слитки",[325]="Вооружен и особо опасен",[328]="Спрятанный ключ",
    [329]="Шпион найден!",[330]="Расписание дежурств",[331]="Доклад Дорену",[332]="Реклама винного магазина",
    [333]="Харлан нуждается в помощи",[334]="Посылка для Турмана",[335]="Благородный напиток",
    [336]="Благородный напиток",[337]="Старый учебник истории",[338]="Зеленые холмы Тернистой долины",[339]="Глава I",
    [340]="Глава II",[341]="Глава III",[342]="Глава IV",[343]="Кстати, о стойкости духа",[344]="Брат Пакстон",
    [345]="Запас чернил",[346]="Возвращение к Кристофу",[347]="Ретбанская руда",[348]="Лихорадка Тернистой долины",
    [349]="Лихорадка Тернистой долины",[350]="Помощь старого друга",[351]="Найди КПХ-17/TN!",
    [353]="Посылка для Грозовой Вершины",[354]="Смерти в семье",[355]="Разговор с Севреном",
    [356]="Патруль в арьергарде",[357]="Личность лича",[358]="Грабители могил",[359]="Обязанности Отрекшихся",
    [360]="Возвращение к мировому судье",[361]="Недоставленное письмо",[362]="Мельницы с привидениями",
    [363]="Резкое пробуждение",[364]="Безмозглые твари",[365]="Поля горя",[366]="Книга Гюнтера",[367]="Новая чума",
    [368]="Новая чума",[369]="Новая чума",[370]="Война с Алым орденом",[371]="Война с Алым орденом",
    [372]="Война с Алым орденом",[373]="Неотправленное письмо",[374]="Доказательство верности",
    [375]="Смертельный холод",[376]="Проклятые",[377]="Преступление и наказание",[378]="Успокоить Гневливого",
    [379]="Утолить жажду",[380]="Паучья низина",[381]="Алый орден",[382]="Красный гонец",
    [384]="Кабаньи ребрышки в пиве",[385]="Охота на кроколисков",[386]="Что происходит?",[387]="Подавление бунта",
    [388]="Цвет крови",[389]="Базиль Тредд",[391]="Бунтовщики в тюрьме",[392]="Таинственный посетитель",
    [393]="Тень прошлого",[394]="Голова чудовища",[395]="Гибель братства",[396]="Аудиенция у короля",
    [397]="За достойную службу",[398]="Разыскивается: Червеглаз",[399]="Скромные дары прошлого",
    [400]="Инструменты для Сталежара",[401]="Ожидание перевода",[402]="[Sirra is Busy]",
    [403]="Охраняемый бочонок Громоваров",[404]="Грязная работа",[405]="Блудный лич",[407]="Поля горя",
    [408]="Семейный склеп",[409]="Доказательство преданности",[410]="Спящая тень",[411]="Возвращение блудного лича",
    [412]="Операция \"Перенаправление\"",[413]="Мерцающий портер",[414]="Портер для Кэдрелла",
    [415]="Новое пиво Регольда",[416]="Ловля крыс",[417]="Месть пилота",[418]="Телcамарские кровяные колбаски",
    [419]="Пропавший пилот",[420]="Наблюдения Сенира",[421]="Проявить себя",[422]="Безрассудство Аругала",
    [423]="Безрассудство Аругала",[424]="Безрассудство Аругала",[425]="Ивар Нечистый",[426]="Нападение на мельницы",
    [427]="Война с Алым орденом",[428]="Пропавшие стражи смерти",[429]="Звериные сердца",[430]="Назад к Квинну",
    [431]="Манящие свечи",[432]="Проклятые трогги!",[433]="Слуга народа",[434]="Нападение!",
    [435]="Сопровождая Эрланда",[436]="Раскопки Сталекрута",[437]="Мертвое поле",[438]="Старая переправа",
    [439]="Необычная находка",[440]="Кольцо с гравировкой",[441]="Роли, который живет в Подгороде",
    [442]="Атака на остров Фенриса",[443]="Лимфа Гнилошкуров",[444]="Происхождение Гнилошкуров",
    [445]="Доставка в Серебряный бор",[446]="Тул Коготь Ворона",[447]="Рецептура смерти",[448]="Доложиться Хадрику",
    [449]="Отчет стражей смерти",[450]="Рецептура смерти",[451]="Рецептура смерти",[452]="Засада в деревне",
    [453]="Поиски таинственного незнакомца",[454]="После засады",[455]="Альгазская битва",
    [456]="Природное равновесие",[457]="Природное равновесие",[458]="Защитница леса",[459]="Защитница леса",
    [460]="В целости и сохранности",[461]="Замаскированный тайник",[463]="Страж Природы",[464]="Боевые знамена",
    [465]="Гамбит Нек'роша",[466]="Поиски огневита",[467]="Найдите Камнекожца",
    [468]="Отчитайтесь перед горным пехотинцем Рокхаром",[469]="Ежедневная доставка",[470]="Прожорливый слизнюк",
    [471]="Тяжкая судьба помощника",[472]="Падение Дун Модра",[473]="Доклад капитану Крепкому Кулаку",
    [474]="Убить Нек'роша",[475]="Ветер тревоги",[476]="Порча Кривой Сосны",[477]="Пересечение границ",
    [478]="Карты и руны",[479]="Расследование в Янтарной Мельнице",[480]="Ткач",[481]="Анализ Далара",
    [482]="Планы Даларана",[483]="Реликвии Пробуждения",[484]="Шкуры молодых кроколисков",[485]="Найти КПХ-9/HL!",
    [486]="Урсал Изверг",[487]="Дорога в Дарнас",[488]="Просьба Зенна",[489]="Искупление вины",
    [491]="Жезл для Бетора",[492]="Новая чума",[493]="Путешествие в предгорья Хилсбрада",[494]="Время нанести удар",
    [495]="Корона Воли",[496]="Эликсир Страдания",[498]="Спасение",[499]="Эликсир Страдания",
    [500]="Награда Раздробленного Хребта",[501]="Эликсир боли",[502]="Эликсир боли",[503]="Гол'дир",
    [504]="Наемники клана Раздробленного Хребта",[505]="Убийцы из Синдиката",[506]="Наследие Блэкмура",
    [507]="Лорд Алиден Перенольд",[508]="Подарок Тареты",[509]="Эликсир агонии",[510]="Зловещие планы",
    [511]="Зашифрованное письмо",[512]="Благородные смерти",[513]="Эликсир агонии",[514]="Письмо Грозовой Вершине",
    [515]="Эликсир агонии",[516]="Погибель Берена",[517]="Эликсир агонии",[518]="Корона Воли",[519]="Корона Воли",
    [520]="Корона Воли",[521]="Корона Воли",[522]="Контракт убийцы",[523]="Смерть барона",[524]="Эликсир агонии",
    [525]="Все больше тайн",[526]="Слитки светлостали",[527]="Битва за Хилсбрад",[528]="Битва за Хилсбрад",
    [529]="Битва за Хилсбрад",[530]="Месть мужа",[531]="Месть Вайрины",[532]="Битва за Хилсбрад",
    [533]="Шпионская работа",[535]="Валлик",[536]="На побережье",[537]="Темный совет",[538]="Южнобережье",
    [539]="Битва за Хилсбрад",[540]="Сохранение знаний",[541]="Битва за Хилсбрад",[542]="Возвращение к Милтону",
    [543]="Тиара Перенольда",[544]="Взлом тюрьмы",[545]="Даларанские патрули",[546]="Сувениры смерти",
    [547]="Меч Гумберта",[549]="Разыскиваются: сторонники Синдиката",[550]="Битва за Хилсбрад",
    [551]="Заколдованный пергамент",[552]="Месть Гелькулара",[553]="Месть Гелькулара",
    [554]="Расшифровщик Грозовая Вершина",[555]="Нежный черепаховый суп",[556]="Каменные талисманы",
    [558]="Автограф Джайны",[559]="Доказательство Фаррена",[560]="Доказательство Фаррена",
    [561]="Доказательство Фаррена",[562]="Эй, Штормград!",[563]="Новое назначение",[564]="Серьезная угроза",
    [565]="Плащ из меха йети",[566]="Разыскивается: Барон Вардус",[567]="Вооружены и очень опасны!",
    [568]="Защита Гром'гола",[569]="Защита Гром'гола",[570]="Чары Мок'тардина",[571]="Чары Мок'тардина",
    [572]="Чары Мок'тардина",[573]="Чары Мок'тардина",[574]="Особые войска",[575]="Спрос и предложение",
    [576]="Смотри в оба",[577]="Добыча шкур",[578]="Камень приливов",[579]="Библиотека Штормграда",
    [580]="Потерянный грог Алкача Виски",[581]="Поиски Йеннику",[582]="Охота за головами",
    [583]="Добро пожаловать в джунгли",[584]="Головы племени Кровавого Скальпа",[585]="Разговор с Неззилоком",
    [586]="Разговор с Ган'зулахом",[587]="Понюшка табака",[588]="Судьба Йеннику",[589]="Поющие кристаллы",
    [590]="Выгодная сделка",[591]="Око разума",[592]="Спасение Йеннику",[593]="Наполнение самоцвета Души",
    [594]="Послание в бутылке",[595]="Пираты Кровавого Паруса",[596]="Ожерелье кровавых костей",
    [597]="Пираты Кровавого Паруса",[598]="Ожерелье расколотых костей",[599]="Пираты Кровавого Паруса",
    [600]="Рудник Торговой Компании",[601]="Элементали воды",[602]="Магический анализ",[603]="Ключ Ансарема",
    [604]="Пираты Кровавого Паруса",[605]="Осколки Поющих кристаллов",[606]="Напугать Трусишку",
    [607]="Возвращение к Маккинли",[608]="Пираты Кровавого Паруса",[609]="Должники вуду",[610]="\"Красавчик\" Дункан",
    [611]="Проклятье приливов",[613]="Вскрыть ногу Моури",[614]="Сундук капитана",[615]="Капитанская сабля",
    [616]="Остров духов",[617]="Вязанка акириса",[618]="Бой с Неголашем",[619]="Приманка для Неголаша",
    [620]="Кушак с монограммой",[621]="Тайна Занзила",[622]="Возвращение к капралу Калебу",[623]="Вязанка акириса",
    [624]="Загадка Кортелло",[625]="Загадка Кортелло",[626]="Загадка Кортелло",[627]="Просьба Кразека",
    [628]="Эксельзиор",[629]="Коварный риф",[630]="Послание в бутылке",[631]="Мост Тандола",[632]="Мост Тандола",
    [633]="Мост Тандола",[634]="Просьба о помощи",[635]="Горный кристалл",[636]="Legends of the Earth <NYI>",
    [637]="Письмо Салли Балу",[638]="Троллебой",[639]="Печать Cтрома",[640]="Сломанная печать",
    [641]="Печать Торадина",[642]="Пойманная принцесса",[643]="Печать Аратора",[644]="Печать Троллебоя",
    [645]="Трол'калар",[646]="Трол'калар",[647]="Самогон Маккрила",[648]="Спасти КПХ-17/TN!",[649]="За медовухой",
    [650]="За медовухой",[651]="Связывающие камни",[652]="Разбить краеугольный камень",[653]="Союзники Мизраэль",
    [654]="Полевые испытания в Танарисе",[655]="Павший Молот",[656]="Призыв принцессы",
    [657]="Новая чума зарождается?",[658]="Новая чума зарождается?",[659]="Новая чума зарождается?",
    [660]="Новая чума зарождается?",[661]="Новая чума зарождается?",[662]="Поиски на глубине",[663]="Эй, там!",
    [664]="Затонувшие печали",[665]="Утонувшее сокровище",[666]="Утонувшее сокровище",[667]="Смерть со дна морского",
    [668]="Утонувшее сокровище",[669]="Утонувшее сокровище",[670]="Утонувшее сокровище",[671]="Зловещая магия",
    [672]="Вызов духов",[673]="Зловещая магия",[674]="Вызов духов",[675]="Вызов духов",[676]="Да падет молот",
    [677]="К оружию!",[678]="К оружию!",[679]="К оружию!",[680]="Настоящая угроза",[681]="Северное поместье",
    [682]="Знаки Стромгарда",[683]="Просьба Сары Балу",[684]="Разыскивается: Марез Клобук",
    [685]="Разыскивается: Отто и лорд Соколиный Шлем",[686]="Королевские почести",[687]="Тельдарин Заблудший",
    [688]="Союзники Мизраэль",[689]="Королевские почести",[690]="Просьба Малина",[691]="На вес золота",
    [692]="Утраченные фрагменты",[693]="Оружие получше кулаков",[694]="Оборона Трелана",[695]="Чары ученика",
    [696]="Атака на башню",[697]="Просьба Малина",[698]="Нехватка ресурсов",[699]="Нехватка ресурсов",
    [700]="Королевские почести",[701]="Коварство ящера",[702]="Коварство ящера",[703]="Жареные крылышки канюка",
    [704]="Судьба Эгмонда",[705]="В поисках жемчуга",[706]="Чары яркого пламени",[707]="Вы нужны Сталекруту!",
    [708]="Черный ящик",[709]="Лекарство от судьбы",[710]="Изучение стихий: Камень",[711]="Изучение стихий: Камень",
    [712]="Изучение стихий: Камень",[713]="Охлаждение горячих голов",[714]="Гиро...чего?",[715]="Жидкий камень",
    [716]="Камень – лучшая одежка!",[717]="Дрожь земли",[718]="Миражи",[719]="Дворф и его инструменты",
    [720]="Предвестник надежды",[721]="Предвестник надежды",[722]="Амулет тайн",[723]="Клятва верности",
    [724]="Клятва верности",[725]="Слухи об угрозе",[726]="Слухи об угрозе",[727]="В Стальгорн за книгой Йагина",
    [728]="В Подгород за книгой Йагина",[729]="Рассеянный геолог",[730]="Неприятности на Темных берегах?",
    [731]="Рассеянный геолог",[732]="Дрожь земли",[733]="Помогите кто чем может!",[734]="Сложная задача",
    [735]="Звезда, Рука и Сердце",[736]="Звезда, Рука и Сердце",[737]="Запретное знание",[738]="Найти Эгмонда",
    [739]="Мурдалок",[741]="Рассеянный геолог",[742]="Большая охота",[743]="Соседство со стаей Неистовства Ветра",
    [744]="Подготовка к церемонии",[745]="Недобрые соседи",[746]="Дворфийские делишки",[747]="Охота начинается",
    [748]="Отравленная вода",[749]="Разграбленный караван",[750]="Охота продолжается",[751]="Разграбленный караван",
    [752]="Скромная просьба",[753]="Скромная просьба",[754]="Очищение колодца Заиндевевшего Копыта",
    [755]="Обряды Матери-Земли",[756]="Тотем Громового Рога",[757]="Обряд Силы",
    [758]="Очищение колодца Громового Рога",[759]="Тотем Буйногривых",[760]="Очищение колодца Буйногривых",
    [761]="Охота на перепелятников",[762]="Посланник зла",[763]="Обряды Матери-Земли",[764]="Торговая Компания",
    [765]="Бригадир Шумовик",[766]="Маззранач",[767]="Обряд прозрения",[768]="Добывание шкур",
    [769]="Сумка из шкуры кодо",[770]="Поцарапанный демоном плащ",[771]="Обряд прозрения",[772]="Обряд прозрения",
    [773]="Обряд мудрости",[775]="Путешествие в Громовой Утес",[776]="Обряды Матери-Земли",[777]="Сложная задача",
    [778]="Сложная задача",[779]="Печать земли",[780]="Боевые вепри",[781]="Attack on Camp Narache",
    [782]="Разорванные союзы",[783]="Внутренняя угроза",[784]="Бей предателей!",[785]="Стратегический союз",
    [786]="Предотвращение агрессии племени Колкар",[787]="Новая Орда",[788]="Кабаньи клыки",[789]="Жала скорпидов",
    [790]="Саркот",[791]="Больше сумок – больше добычи!",[792]="Злобные фамильяры",[793]="Разорванные союзы",
    [794]="Медальон клана Пылающего Клинка",[795]="Печать земли",[804]="Саркот",[805]="Деревня Сен'джин",
    [806]="Сгущаются черные тучи",[808]="Череп Миншины",[809]="Ак'Зелот",[812]="Нужда в исцелении",
    [813]="Поиски противоядия",[815]="Хорошенький омлет",[816]="Пропавший, но не забытый",[817]="Полезная добыча",
    [818]="Растворитель",[819]="Пустой бочонок Чэня",[821]="Пустой бочонок Чэня",[822]="Пустой бочонок Чэня",
    [823]="Явиться к Оргнилу",[824]="Дже'неу из Служителей Земли",[825]="Обломки кораблекрушения",[826]="Залазан",
    [827]="Скала Черепа",[828]="Маргоз",[829]="Ниру Огненный Клинок",[830]="Приказы адмирала",
    [831]="Приказы адмирала",[832]="Пылающие тени",[833]="Священное погребение",[834]="Ветра пустыни",
    [835]="Обеспечение безопасного сообщения",[836]="Спасти КПХ-9/HL!",[837]="Вторжение",[838]="Некроситет",
    [840]="Новобранец Орды",[841]="Еще один источник энергии?",[842]="Рекрутский набор Перекрестка",
    [843]="Ответный удар Ганна",[844]="Равнинные долгоноги",[845]="Жевры",[846]="Месть Ганна",[847]="Коварство ящера",
    [848]="Споры грибов",[849]="Месть Ганна",[850]="Главари племени Колкар",[851]="Верог Дервиш",
    [852]="Хэзрул Кровавая Отметина",[853]="Аптекарь Зама",[854]="Путешествие в Перекресток",[855]="Наручи кентавров",
    [857]="Слеза Лун",[858]="Зажигание",[860]="Сергра Черный Шип",[862]="Похлебка из пещерной крысы",[863]="Бегство",
    [864]="Возвращение к аптекарю Зинг",[866]="Образцы корней",[867]="Гарпии-налетчики",[868]="Охота за яйцами",
    [869]="Ящеры-воры",[870]="Забытые пруды",[871]="Прекратить набеги",[872]="Конец бесчинствам",[873]="Иша Авак",
    [874]="Марен Небесная Провидица",[875]="Лейтенанты гарпий",[876]="Серена Кровавое Перо",[877]="Застывший оазис",
    [878]="Воюющие племена",[879]="Предатель в наших рядах",[880]="Измененные существа",[881]="Ичияки",
    [882]="Ишамухал",[883]="Лакота'мани",[884]="Оватанка",[885]="Ваште Пауни",[886]="Оазисы Степей",
    [887]="Флибустьеры Южных морей",[888]="Украденное добро",[889]="Дух ветра",[890]="Пропавший груз",
    [891]="Пушки крепости Северной Стражи",[892]="Пропавший груз",[893]="Предпочитаемое оружие",[894]="Самофланж",
    [895]="Разыскивается: Барон Дольноберег",[896]="Удача шахтера",[897]="Жнец",[898]="Свобода!",
    [899]="Огонь ненависти",[900]="Самофланж",[901]="Самофланж",[902]="Самофланж",[903]="Хищники Степей",
    [905]="Разъяренные смертехваты",[906]="Предатель в наших рядах",[907]="Разъяренные рокочущие ящерицы",
    [908]="Среди руин",[911]="Врата пограничья",[913]="Крик грозового змея",[915]="Женщинам – цветы, детям – ...",
    [916]="Яд чащобного паука",[917]="Яйцо чащобного паука",[918]="Саженцы древесника",[919]="Ростки древесника",
    [920]="Зов Тенарона",[921]="Венец Земли",[922]="Релиан Зеленый Костер",[923]="Опухоли",
    [925]="Отпечаток копыта Кэрна",[926]="Треснувший камень силы",[927]="Сердце, поросшее мхом",[928]="Венец Земли",
    [929]="Венец Земли",[930]="Светящийся плод",[931]="Мерцающий росток",[932]="Извращенная ненависть",
    [933]="Венец Земли",[934]="Венец Земли",[935]="Венец Земли",[936]="Помощь верховному друиду Руническому Тотему",
    [937]="Зачарованная поляна",[938]="Туманна",[939]="Флейта Ксаварика",[940]="Тельдрассил",[941]="Сердце-семя",
    [942]="Рассеянный геолог",[943]="Рассеянный геолог",[944]="Меч Властителя",[945]="Спасение Терилун",
    [947]="Пещерные грибы",[948]="Ону",[949]="Лагерь Сумеречного Молота",[950]="Возвращение к Ону",
    [951]="Реликвии Матистры",[952]="Роща Древних",[953]="Падение Амет'Арана",[954]="Башал'Аран",[955]="Башал'Аран",
    [956]="Башал'Аран",[957]="Башал'Аран",[958]="Инструменты высокорожденных",[959]="Неприятности в порту",
    [960]="Размышление Ону",[961]="Размышление Ону",[962]="Змеецвет",[963]="Во имя вечной любви",
    [964]="Фрагменты скелетов",[965]="Башня Алталакса",[966]="Башня Алталакса",[967]="Башня Алталакса",
    [968]="\"Подземные Силы\"",[969]="Да пребудет с тобой удача!",[970]="Башня Алталакса",[972]="Сапта воды",
    [973]="Башня Алталакса",[974]="Найти источник",[975]="Сокровище Мау'ари",[976]="Поставка для Аубердина",
    [977]="Йети где-то рядом…",[978]="Осененные луной дикие совухи",[979]="В поисках Раншаллы",
    [980]="Новые источники",[981]="Башня Алталакса",[982]="Безбрежное море, глубокий океан",[983]="Жужжалка 827",
    [984]="Насколько велика угроза?",[985]="Насколько велика угроза?",[986]="Пропавший хозяин",
    [990]="Путь в Ясеневый лес",[991]="Раэна – санитар Ясеневого леса",[992]="Исследование воды",
    [993]="Пропавший хозяин",[994]="Спасение с помощью силы",[995]="Спасение с помощью скрытности",
    [996]="Оскверненный ветроцвет",[997]="Земля Деналана",[998]="Оскверненный ветроцвет",
    [999]="Когда сны превращаются в кошмары",[1000]="Новое пограничье",[1001]="Жужжалка 411",[1002]="Жужжалка 323",
    [1003]="Жужжалка 525",[1004]="Новое пограничье",[1005]="Шныряющие за стеной",[1006]="Что скрывается за стеной",
    [1007]="Древняя статуэтка",[1008]="Зорамское взморье",[1009]="Руузель",[1010]="Батранов волос",
    [1011]="Чума Отрекшихся",[1012]="Безумные друиды",[1013]="Книга Ура",[1014]="Смерть Аругалу!",
    [1015]="Новое пограничье",[1016]="Браслеты элементалей",[1017]="Маг-призыватель",[1018]="Новое пограничье",
    [1019]="Новое пограничье",[1020]="Лекарство Орендила",[1021]="Сатиры коварны! Дриады в опасности!",
    [1022]="Воющая долина",[1023]="Раэна – санитар Ясеневого леса",[1024]="Раэна – санитар Ясеневого леса",
    [1025]="Лучшая защита – нападение",[1026]="Раэна – санитар Ясеневого леса",
    [1027]="Раэна – санитар Ясеневого леса",[1028]="Раэна – санитар Ясеневого леса",
    [1029]="Раэна – санитар Ясеневого леса",[1030]="Раэна – санитар Ясеневого леса",[1031]="Ветвь Кенария",
    [1032]="Убийство сатиров!",[1033]="Слеза Элуны",[1034]="Руины Звездной Пыли",[1035]="Зеркало Небес",
    [1036]="Суши весла, сухопутная крыса",[1037]="Велинда Песнь Звезд",[1038]="Эффекты Велинды",
    [1039]="Порт в Степях",[1040]="Дорога до Пиратской Бухты",[1041]="Путь каравана",[1042]="Семья Карвин",
    [1043]="Коса Элуны",[1044]="Полученные ответы",[1045]="Раэна – санитар Ясеневого леса",
    [1046]="Раэна – санитар Ясеневого леса",[1047]="Новое пограничье",[1048]="В монастырь Алого ордена",
    [1049]="\"Компендиум павших\"",[1050]="\"Мифология Титанов\"",[1051]="Месть Воррела",
    [1052]="По пути Алого ордена",[1053]="Во имя Света!",[1054]="Устранение угрозы",
    [1055]="Раэна – санитар Ясеневого леса",[1056]="Путешествие к Пику Каменного Когтя",
    [1057]="Возвращение Горелой Долины",[1058]="Лесная магия Джин'Зила",[1059]="Возвращение Обугленной долины",
    [1060]="Письмо Джин'Зилу",[1061]="Духи Каменного Когтя",[1062]="Вторжение гоблинов",[1063]="Мудрая старуха",
    [1064]="Помощь Отрекшихся",[1065]="Путешествие в Мельницу Таррен",[1066]="Невинная кровь",
    [1067]="Возвращение в Громовой Утес",[1068]="Механические измельчители",[1069]="Яйца мохового паука",
    [1070]="На страже в Когтистых горах",[1071]="Отсрочка для гнома",[1072]="Старый коллега",
    [1073]="Неумение + реактивы = потеха!",[1074]="Неумение + реактивы = потеха!",[1075]="Свиток от Маурена",
    [1076]="Демоны в Западном Крае",[1077]="Особая посылка для Гаксима",[1078]="Поиск для Маурена",
    [1079]="Секретная операция – Альфа",[1080]="Секретная операция – Бета",[1081]="Приглашение от Тиранды",
    [1082]="Новости для часового Тенисил",[1083]="Разъяренные духи",[1084]="Раны Дерев",
    [1085]="На страже в Когтистых горах",[1086]="Аэропорт ветролетов",[1087]="Наследие Кенария",[1088]="Ордан",
    [1089]="Логово",[1090]="Приказы Геренцо",[1091]="Новости для Каэлы",[1092]="Приказы Геренцо",
    [1093]="Супер-дровосек 6000",[1094]="Дальнейшие указания",[1095]="Дальнейшие указания",
    [1096]="Геренцо Терминатрикс",[1097]="Просьба Элмора",[1098]="Пропавшие стражи смерти",[1099]="Гоблины победили!",
    [1100]="Дневник Хмурня",[1101]="Хозяйка Лабиринтов",[1103]="Зов воды",[1104]="Яд Соляных равнин",
    [1105]="Крепкие панцири",[1106]="Мартек Изгой",[1107]="Средство против трения",[1108]="Индарилий",
    [1109]="Груды гуано",[1110]="Обломки болидов",[1111]="Управляющий пристанью Головокружилкинс",
    [1112]="Детали для Крейвела",[1113]="Сердца Доблести",[1114]="Заказ гномов",[1115]="Сплетник",
    [1116]="Сонная пыль в болоте",[1117]="Сплетни для Крейвела",[1118]="Назад в Пиратскую Бухту",
    [1119]="Смесь Занзила и \"Дурацкое Крепкое\"",[1120]="Напоить гномов",[1121]="Напоить гоблинов",
    [1122]="Возвращение к Пуззыриксу",[1123]="Рабин Сатурна",[1124]="Пустошь",[1125]="Духи Южного Ветра",
    [1126]="Улей в башне",[1127]="\"Дурацкое Крепкое\"",[1130]="Весть от Мелора",[1131]="Сталезуб",
    [1132]="Fiora Longears",[1133]="Путешествие в Астранаар",[1134]="Величавые виверны Каменного Когтя",
    [1135]="Яд из Скального гнездовья",[1136]="Ледочрев",[1137]="Новости для Пшикса",[1138]="Дары моря",
    [1139]="Утерянные таблички Воли",[1140]="Башня Алталакса",[1141]="Семья и рыболовная удочка",
    [1142]="Последнее желание",[1143]="Башня Алталакса",[1144]="Импортер Вилликс",[1145]="Рой растет",
    [1146]="Рой растет",[1147]="Рой растет",[1148]="Части роя",[1149]="Испытание веры",
    [1150]="Испытание выносливости",[1151]="Испытание силы",[1152]="Испытание знаний",[1153]="Образец новой руды",
    [1154]="Испытание знаний",[1159]="Испытание знаний",[1160]="Испытание знаний",[1164]="Ограбить воров",
    [1166]="Заботы властителя Мок'Морокка",[1167]="Башня Алталакса",[1168]="Армия Черного дракона",
    [1169]="Корни угрозы",[1170]="Выводок Ониксии",[1171]="Выводок Ониксии",[1172]="Выводок Ониксии",
    [1173]="Вызов властителю Мок'Морокку",[1175]="Помехи на трассе",[1176]="Уменьшение веса",[1177]="Моя голодный!",
    [1178]="Гоблинская поддержка",[1179]="Братья Медноштиф",[1180]="Гоблинская поддержка",
    [1181]="Гоблинская поддержка",[1182]="Гоблинская поддержка",[1183]="Гоблинская поддержка",[1184]="Части роя",
    [1185]="А под хитином было...",[1186]="Восемнадцатый пилот",[1187]="Доработка Раззерика",
    [1188]="Безопасность превыше всего",[1189]="Безопасность превыше всего",[1190]="Только вперед",
    [1191]="Помеха Замека",[1192]="Индарилиевая руда",[1193]="Сломанная западня",[1194]="Чертежи Риззла",
    [1195]="Священное пламя",[1196]="Священное пламя",[1197]="Священное пламя",[1198]="В поисках Талрида",
    [1199]="Наступление сумерек",[1200]="Жестокость Черных Глубин",[1201]="Тераморские шпионы",[1202]="Доки Терамора",
    [1203]="Ярлу нужен клинок",[1204]="Суп из глинистой черепахи с крабами",[1205]="Волокун",
    [1206]="Ярлу нужны глаза",[1218]="Лягушачьи лапки",[1219]="Орочье донесение",[1220]="Капитан Ваймс",
    [1221]="Корни Синелиста",[1222]="Побег Вонючки",[1238]="Потерянный рапорт",[1239]="Отрубленная Голова",
    [1240]="Тролль-знахарь",[1241]="Пропавший дипломат",[1242]="Пропавший дипломат",[1243]="Пропавший дипломат",
    [1244]="Пропавший дипломат",[1245]="Пропавший дипломат",[1246]="Пропавший дипломат",[1247]="Пропавший дипломат",
    [1248]="Пропавший дипломат",[1249]="Пропавший дипломат",[1250]="Пропавший дипломат",[1251]="Черный щит",
    [1252]="Лейтенант Павал Рит",[1253]="Черный щит",[1258]="…с крабами",[1259]="Лейтенант Павал Рит",
    [1260]="Морган Штерн",[1261]="Марг говорит",[1262]="Сообщение для Зора",[1263]="Сожженная Таверна",
    [1264]="Пропавший дипломат",[1265]="Пропавший дипломат",[1266]="Пропавший дипломат",[1267]="Пропавший дипломат",
    [1268]="Подозрительные следы копыт",[1269]="Лейтенант Павал Рит",[1270]="Побег Вонючки",
    [1271]="Праздник в \"Печальном отшельнике\"",[1272]="Найти Рита <CHANGE INTO GOSSIP>",[1273]="Допрос Рита",
    [1274]="Пропавший дипломат",[1275]="Исследование порчи",[1276]="Черный щит",
    [1281]="Песня Джима <CHANGE TO GOSSIP>",[1282]="Зовут его Улыбка Джим",[1284]="Подозрительные следы копыт",
    [1285]="Солдаты Даэлина",[1286]="Дезертиры",[1287]="Дезертиры",[1288]="Донесение Ваймса",[1301]="Джеймс Хьяль",
    [1302]="Джеймс Хьяль",[1318]="Неоконченное дело Гордоков",[1319]="Черный щит",[1320]="Черный щит",
    [1321]="Черный щит",[1322]="Черный щит",[1323]="Черный щит",[1324]="Пропавший дипломат",
    [1338]="Заказ Грозовой Вершины",[1339]="Задание Грозовой Вершины",[1358]="Образец для Хелбрима",
    [1359]="Посылка для Зинг",[1360]="Возвращенные сокровища",[1361]="Регтар Врата Смерти",[1362]="Кентавры Пустошей",
    [1363]="Задание Мазена",[1364]="Задание Мазена",[1365]="Вождь Дез'хеп",[1366]="Награда за кентавров",
    [1367]="Союз с племенем Маграм",[1368]="Союз с племенем Гелкис",[1369]="Россыпи Слез",[1370]="Похищение припасов",
    [1371]="Игрушка для Варуга",[1372]="Правда и только правда",[1373]="Онгеку",[1374]="Вождь Джен",
    [1375]="Вождь Шак",[1380]="Вождь Храта",[1381]="Вождь Храта",[1382]="Странный союз",
    [1383]="Правда и только правда",[1384]="Набег на племя Колкар",[1385]="Политика силы",
    [1386]="Нападение на племя Колкар",[1387]="Награда за кентавров",[1388]="Правда и только правда",
    [1389]="Кристаллы дренетиста",[1391]="Правда и только правда",[1392]="Нобору Дубина",[1393]="Побег Галена",
    [1394]="Финальное испытание",[1395]="Поставки для Стражей Пустоты",[1396]="Атака тварей",[1398]="Плавник",
    [1418]="Ника Алый Шрам",[1419]="Койоты-воры",[1420]="Донесение Хелгруму",[1421]="Пропавший караван",
    [1422]="Угроза с моря",[1423]="Потерянные припасы",[1424]="Озеро Слез",[1425]="Доставка груза",
    [1426]="Угроза с моря",[1427]="Угроза с моря",[1428]="Продолжающаяся угроза",[1429]="Изгнанник Атал'ай",
    [1430]="Свежее мясо",[1431]="Отношения с Альянсом",[1432]="Отношения с Альянсом",[1433]="Отношения с Альянсом",
    [1434]="Опоганенные сатиры",[1435]="Сжигание душ",[1436]="Отношения с Альянсом",[1437]="Расследование Валарриэля",
    [1438]="Расследование Валарриэля",[1439]="Поиски Тираниса",[1442]="Поиск самоцвета Кора",
    [1444]="Возвращение к Фел'зерулу",[1445]="Храм Атал'Хаккар",[1446]="Джаммал'ан Пророк",
    [1447]="Пропавший дипломат",[1448]="В поисках Храма",[1449]="Во Внутренние земли",
    [1450]="Укротитель грифонов Разящий Коготь",[1451]="Рапсод Землекоп",[1452]="Калимдорский коктейль",
    [1453]="Дела Поисковой корпорации в Пустошах",[1454]="Пожитки Карнитола",[1455]="Пожитки Карнитола",
    [1456]="Пожитки Карнитола",[1457]="Пожитки Карнитола",[1458]="Реагенты для Поисковой корпорации",
    [1464]="Сапта огня",[1465]="Расследование Валарриэля",[1466]="Реагенты для Поисковой корпорации",
    [1468]="Детская неделя",[1474]="Связывание",[1476]="Чистые сердца",[1479]="Купина Вечности",
    [1480]="Осквернитель душ",[1481]="Осквернитель душ",[1482]="Осквернитель душ",[1483]="Зиз Физзикс",
    [1485]="Злобные фамильяры",[1486]="Шкуры загадочных существ",[1487]="Искоренение Скверны",
    [1488]="Осквернитель душ",[1489]="Хамуул Рунический Тотем",[1490]="Нара Буйногривая",[1491]="Умный напиток",
    [1499]="Злобные фамильяры",[1513]="Оковы",[1559]="Секрет изготовления световой бомбы",[1655]="Партия руды Балора",
    [1689]="Оковы",[1690]="Расправа над Скитальцами Пустыни",[1706]="Доспехи Гриманда",
    [1781]="Фолиант Божественности",[1861]="Зеркальное озеро",[1899]="Стражи смерти",[2000]="Рокар Тень Клинка",
    [2038]="Пропавшее снаряжение Бинглза",[2039]="Найти Бинглза",[2040]="Битва под землей",[2041]="Разговор с Шони",
    [2078]="Месть Гиромачта",[2098]="Помощь Гиромачту",[2118]="Зачумленные земли",[2138]="Избавление от заразы",
    [2139]="Надежда Тарнариуна",[2158]="Отдых и покой",[2159]="Посылка в Доланаар",[2160]="Припасы для Таннока",
    [2178]="Спокойная жизнь долгоногов",[2198]="Рассыпавшееся ожерелье",[2199]="Мудрость за деньги",
    [2200]="Назад в Ульдаман",[2201]="Время собирать камни",[2202]="В Ульдаман за реактивом",
    [2203]="Пробежка по Бесплодным землям-2",[2239]="Донесение Онина",[2242]="Зов судьбы",[2260]="Директива Эриона",
    [2278]="Платиновые диски",[2279]="Платиновые диски",[2282]="Лесопилка Альтера",[2283]="Пропавшее ожерелье",
    [2300]="ШРУ",[2318]="Трудности перевода",[2338]="Трудности перевода",[2339]="Найти самоцветы и источник энергии",
    [2340]="Принести самоцветы",[2341]="Пропавшее ожерелье, этап 3",[2360]="Матиас и Братство Справедливости",
    [2383]="Записка на пергаменте",[2398]="Потерянные дворфы",[2399]="Росток папоротника",[2418]="Силовые камни",
    [2438]="Изумрудный ловец снов",[2439]="Платиновые диски",[2458]="Надежное прикрытие",[2480]="Помощь Хинотта",
    [2498]="Возвращение к Деналану",[2499]="Дубохмур",[2500]="Пробежка по Бесплодным землям",
    [2501]="Пробежка по Бесплодным землям-2",[2518]="Слезы Луны",[2519]="Храм Луны",[2520]="Жертвоприношение Сатры",
    [2521]="Служба для Кум'иша",[2522]="Попытки Кум'иша",[2523]="Оскверненный песнецвет",[2541]="Спящий друид",
    [2561]="Друид-медведь",[2581]="Челюсти гиены-хохотуна",[2582]="Ярость веков",[2583]="Жизненная сила вепря",
    [2584]="Дух вепря",[2585]="Решительный удар",[2586]="Скорпоковая соль",[2601]="Укус василиска",
    [2602]="Непогрешимый разум",[2603]="Стойкость стервятника",[2604]="Духовное превосходство",
    [2605]="Жаждущий гоблин",[2609]="Прикосновение Занзила",[2621]="Опозоренный",[2622]="Пропавшие приказы",
    [2623]="Болотный говорун",[2641]="Маленький секрет Поливалки",[2661]="Посылка для Синя",
    [2662]="Эликсир Ноггенфоггера",[2681]="Камни, что связывают нас",[2701]="Герои древних времен",
    [2702]="Герои древних времен",[2721]="Кирит",[2741]="Супер Яйц-О-Матик",[2742]="Рин'джи в ловушке",
    [2743]="Покров Тьмы",[2744]="Охотник на демонов",[2745]="Проникновение в крепость",[2746]="Все по порядку",
    [2747]="Необычное яйцо",[2748]="Хорошее яйцо",[2749]="Обычное яйцо",[2765]="Кузнец-умелец!",
    [2766]="Найти ККX-22/FE!",[2767]="Спасти ККX-22/FE!",[2768]="Изыскательский жезл",[2769]="Братья Медноштиф",
    [2773]="Мифриловый парень",[2781]="Разыскивается: Калиф Жало Скорпида",[2782]="Секрет Рин'джи",
    [2783]="Незначительные разногласия",[2784]="Попавший в немилость",[2801]="Печальная история",
    [2821]="Знак качества",[2822]="Знак качества",[2841]="Техновойны",[2842]="Главный инженер Скути",
    [2843]="Поехалиии!",[2844]="Великан-опекун",[2845]="Шая-бродяжница",[2860]="Мастер школы Дикаря",
    [2861]="Миссия Табеты",[2862]="Война с племенем Древолапов",[2863]="Истребление вожаков",[2864]="Тран'рек",
    [2865]="Панцири скарабеев",[2866]="Руины Соларсаля",[2867]="Возвращение в Крепость Оперенной Луны",
    [2869]="Борьба с Гребнем Ненависти",[2870]="Борьба с лордом Шалзару",[2871]="Доставка реликвии",
    [2872]="Долг Столи",[2873]="Посылка Столи",[2874]="Ром для Маккинли",[2875]="Разыскивается: Андре Огнебородый",
    [2876]="Расписание кораблей",[2877]="Зачистка Осклизлой скалы",[2878]="Оскверненный песнецвет",
    [2879]="Посох равноденствия",[2880]="Ожерелья троллей",[2882]="Золото Куэрго",[2902]="Разведка планов Древолапов",
    [2903]="Планы битвы",[2904]="Катавасия",[2922]="Промыть мозг Техботу",[2923]="Мехмастер Замыкалец",
    [2924]="Базовый элемент",[2925]="Базовые элементы Клацморта",[2926]="Новая формула",[2927]="На другой день",
    [2928]="Сооружение автогиробуророек",[2929]="Великое предательство",[2930]="Спасение данных",
    [2931]="Поручение Чугонотрубза",[2932]="Предупреждение",[2933]="Бутыли с ядом",
    [2934]="Неповрежденная ядовитая железа",[2935]="Разговор с мастером Гадрином",[2936]="Паучья богиня",
    [2937]="Призыв Шадры",[2938]="Яд в Подгород",[2939]="В поисках знаний",[2940]="\"Фералас: История\"",
    [2941]="В обмен на книгу",[2942]="Завтрашний камень",[2943]="Возвращение к Троясу",[2944]="Супер-щёлк FX",
    [2945]="Кольцо, покрытое грязью",[2946]="Посмотрим, что будет дальше",[2947]="Возвращение кольца",
    [2948]="Гномское усовершенствование",[2949]="Возвращение кольца",[2950]="Переделка кольца",[2951]="Чистер 5200!",
    [2952]="Чистер 5200!",[2953]="Работа для Чистера",[2954]="Каменный Страж",[2962]="Сильное зеленое свечение",
    [2963]="Ульдумские чудеса",[2964]="Новое задание",[2965]="Ульдумские чудеса",[2966]="Посмотрим, что будет дальше",
    [2967]="Возвращение в Громовой Утес",[2968]="Новое задание",[2969]="Свободу всем живым существам!",
    [2970]="Небольшое возмездие",[2972]="Небольшое возмездие",[2973]="Новый сверкающий плащ",
    [2974]="Зловещее открытие",[2975]="Огры Фераласа",[2976]="Зловещее открытие",[2977]="Возвращение в Стальгорн",
    [2978]="Свиток Гордунни",[2979]="Темный обряд",[2980]="Огры Фераласа",[2981]="Опасность в Фераласе",
    [2986]="Зов Воды",[2987]="Кобальт Гордунни",[2988]="Тролльи клетки",[2989]="Алтарь Зула",
    [2990]="Тадиус Мрачная Тень",[2991]="Медальон Некрума",[2992]="Прорицание",[2993]="Назад во Внутренние земли",
    [2994]="Спасение Остроклюва",[3001]="В поисках Страхада",[3002]="Сфера Гордунни",[3022]="Не кантовать!",
    [3042]="Троллье месиво",[3062]="Темное сердце",[3120]="Зеленый знак",[3121]="Странная просьба",
    [3122]="Возвращение к знахарю Узер'и",[3123]="Испытание сосуда",[3124]="Уменьшенный гиппогриф",
    [3125]="Уменьшенный лесной дракончик",[3126]="Уменьшенный древень",[3127]="Уменьшенный горный великан",
    [3128]="Природные материалы",[3129]="Оружие духа",[3130]="Борьба с Гребнем Ненависти",[3141]="Лорамус",
    [3161]="Газ'рилльское украшение",[3181]="Рог чудовища",[3182]="Доказательство собственности",[3201]="Наконец-то!",
    [3221]="Беседа с Ренферрелом",[3261]="Джорн Небесный Провидец",[3281]="Похищенное серебро",
    [3321]="Не ее ли ищете?",[3341]="Да сгинет Хладовей",[3361]="Беда беженца",[3362]="Долина Кактусов",
    [3363]="Оскверненный песнецвет",[3364]="Жгучая бражка",[3365]="Возвращение кружки",[3366]="Светящийся осколок",
    [3367]="Камни Сунтары",[3368]="Камни Сунтары",[3369]="Кошмары",[3370]="Кошмары",[3371]="Правосудие дворфов",
    [3372]="Отпусти их",[3373]="Сущность Эраникуса",[3374]="Сущность Эраникуса",[3375]="Запасной фиал",
    [3376]="Сразить Остроклыка!",[3377]="Молитва Элуне",[3379]="Мастер по тенеткани",[3380]="Затонувший храм",
    [3381]="Встреча с господином",[3402]="Черный рынок",[3421]="Возвращение",[3441]="Божественное воздаяние",
    [3442]="Неугасимое пламя",[3443]="Древко факела",[3444]="Круглый камень",[3445]="Затонувший храм",
    [3446]="Во глубине болот",[3447]="Тайна камня",[3448]="Передача поручения",[3449]="Чародейские руны",
    [3450]="Легкая доставка",[3451]="Сигнал \"Взять на борт!\"",[3452]="Защита пламени",[3453]="Факел воздаяния",
    [3454]="Факел воздаяния",[3461]="Возвращение к Тимору",[3462]="Оруженосец Малтрейк",[3463]="Задай им жару!",
    [3481]="Безделушки...",[3482]="<NYI> <TXT> The Pocked Black Box",[3483]="Сигнал \"Взять на борт!\"",
    [3501]="Счет идет на большие числа",[3502]="Дренейский хлам...",[3503]="Встреча с господином",
    [3504]="Предательница",[3505]="Предательница",[3506]="Предательница",[3507]="Предательница",[3508]="Минуя охрану",
    [3509]="Имя Зверя",[3510]="Имя Зверя",[3511]="Имя Зверя",[3512]="Судя по словам Эраникуса...",
    [3513]="Свиток с рунами",[3514]="Мощь Орды",[3517]="Тайненькое знаньице",[3518]="Доставка Магате",
    [3519]="Друг в беде",[3520]="Духи крикунов",[3521]="Противоядие для Иверрона",[3522]="Противоядие для Иверрона",
    [3523]="Плеть в холмах",[3524]="Останки на берегу",[3526]="Гоблинское инженерное дело",
    [3527]="Пророчество Мошару",[3528]="Бог Хаккар",[3541]="Доставка Джес'римону",[3542]="Доставка Андрону Ганту",
    [3561]="Доставка верховному магу Ксилему",[3562]="Плата Магаты Джедиге",[3563]="Плата Джес'римона Джедиге",
    [3564]="Плата Андрона Джедиге",[3565]="Плата Ксилема Джедиге",[3566]="Восстань, Обсидион!",
    [3567]="Умный в гору не пойдет...",[3568]="Разносчик порчи",[3569]="Разносчик порчи",[3570]="Разносчик порчи",
    [3601]="Оскорбленный Ким'джаель",[3602]="Азшарит",[3621]="Создание отравы Скверны",
    [3625]="Зачарованное азшаритовое оружие, отравленное Скверной",[3626]="Возвращение в Выжженные земли",
    [3627]="Воссоединить расколотый амулет",[3635]="Гномское инженерное дело",[3647]="Продление членского билета",
    [3681]="Фолиант Божественности",[3701]="Дымящиеся руины Тауриссана",[3702]="Дымящиеся руины Тауриссана",
    [3721]="Собственный ККХ",[3741]="Ожерелье Хилари",[3761]="Почва Ун'Горо",
    [3762]="Помощь верховному друиду Руническому Тотему",[3763]="Помощь верховному друиду Оленьему Шлему",
    [3764]="Почва Ун'Горо",[3765]="Проблема за морем",[3781]="Изучение рассветницы",[3782]="Изучение рассветницы",
    [3783]="Йети где-то рядом…",[3784]="Помощь верховному друиду Руническому Тотему",[3785]="Изучение рассветницы",
    [3786]="Изучение рассветницы",[3787]="Кинтис Пламень",[3788]="Просьба друида",
    [3789]="Помощь верховному друиду Оленьему Шлему",[3790]="Помощь верховному друиду Оленьему Шлему",
    [3791]="Тайна рассветницы",[3792]="Рассветница для Крепости Оперенной Луны",[3801]="Наследие Черного Железа",
    [3802]="Наследие Черного Железа",[3803]="Рассветница для Дарнаса",[3804]="Рассветница для Громового Утеса",
    [3821]="Скала Молота Ужаса",[3822]="Кром'Грул",[3823]="Угасание Огненного Чрева",[3824]="Гор'теш Жестокий",
    [3825]="Голова огра на палочке = вечеринка",[3841]="Бездомный сиротка",[3842]="Инкубатор",
    [3843]="Новый член семьи",[3844]="Тайна, покрытая мраком",[3861]="Куд-кудаааа!",[3881]="Спасение экспедиции",
    [3882]="Игра в кости",[3883]="Экология чужих",[3884]="Дневник Вилидена",[3901]="Игрушки-погремушки",
    [3902]="Поиски старой одежды",[3903]="Милли Осворт",[3904]="Урожай Милли",
    [3905]="Уведомление о поставке винограда",[3906]="Дисгармония пламени",[3907]="Дисгармония пламени",
    [3908]="Тайна, покрытая мраком",[3909]="Эликсир Видере",[3911]="Последняя Стихия",
    [3912]="Встречаемся на кладбище",[3913]="Замогильная история",[3914]="Меч Линкена",[3921]="Венаки Бенике",
    [3922]="Металлические заготовки",[3923]="Рилли Грязегоб",[3924]="Руководство по самофланжу",
    [3941]="Помощь гномов",[3942]="Память Линкена",[3961]="Приключения Линкена",[3962]="Один в поле не воин",
    [3981]="Командир Гор'шак",[3982]="Что происходит?",[4001]="Что происходит?",[4002]="Восточные королевства",
    [4003]="Спасение принцессы",[4004]="Спасенная принцесса",[4005]="Аквамонтос",[4021]="Контратака!",
    [4022]="Вкус пламени",[4023]="Вкус пламени",[4024]="Вкус пламени",[4041]="Эликсир Видере",
    [4061]="Восстание машин",[4062]="Восстание машин",[4063]="Восстание машин",
    [4081]="УНИЧТОЖИТЬ НА МЕСТЕ: Дворфы Черного Железа",
    [4082]="УНИЧТОЖИТЬ НА МЕСТЕ: Высокопоставленные чины Черного Железа",[4083]="Призрачный кубок",
    [4084]="Серебряное сердце",[4101]="Очищение Оскверненного леса",[4102]="Очищение Оскверненного леса",
    [4103]="Лекарство из охотничьих трофеев",[4104]="Лекарство из минералов",[4105]="Лекарство из оскверненных трав",
    [4106]="Лекарство из оскверненных шкур",[4107]="Лекарство из распыленных предметов",
    [4108]="Лекарство из охотничьих трофеев",[4109]="Лекарство из минералов",[4110]="Лекарство из оскверненных трав",
    [4111]="Лекарство из оскверненных шкур",[4112]="Лекарство из распыленных предметов",
    [4113]="Оскверненный песнецвет",[4114]="Оскверненный песнецвет",[4115]="Оскверненный ветроцвет",
    [4116]="Оскверненный песнецвет",[4117]="Оскверненный кнутокорень",[4118]="Оскверненный песнецвет",
    [4119]="Оскверненный ночной дракон",[4120]="Сила порчи",[4121]="Опасное положение",[4122]="Грарк Лоркруб",
    [4123]="Сердце горы",[4124]="Пропавший курьер",[4125]="Пропавший курьер",[4126]="Харли Чернопых",
    [4127]="Разбитая лодка",[4128]="Рагнар Громовар",[4129]="Тайна ножа",[4130]="Сверхзнание",
    [4131]="Гноллы из стаи Древолапов",[4132]="Операция:смерть Кузне Гнева",[4133]="Вивиана Лягроб",
    [4134]="Украденный рецепт громоварского",[4135]="Гудящая Бездна",[4136]="Риббли Крутипроб",
    [4141]="Муиджин и Ларион",[4142]="Визит к Грегану",[4143]="Туман зла",[4144]="Побеги кровоцвета",
    [4145]="Ларион и Муиджин",[4146]="Питание для шокера",[4147]="Мастерская Марвона",
    [4181]="Гоблинское инженерное дело",[4182]="Драконья угроза",[4183]="Подлинные хозяева",
    [4184]="Подлинные хозяева",[4185]="Подлинные хозяева",[4186]="Подлинные хозяева",[4201]="Приворотное зелье",
    [4221]="Оскверненный ветроцвет",[4222]="Оскверненный ветроцвет",[4223]="Подлинные хозяева",
    [4224]="Подлинные хозяева",[4241]="Маршал Винздор",[4242]="Утраченная надежда",[4243]="В поисках Чи-Та 3",
    [4244]="В поисках Чи-Та 3",[4245]="В поисках Чи-Та 3",[4261]="Древний дух",[4262]="Подчинитель Пирон",
    [4263]="Опалитель!",[4264]="Измятая записка",[4265]="Освобожденный из улья",[4266]="Благодарность за отвагу",
    [4267]="Возвышение силитидов",[4281]="Посылка в Таланаар",[4282]="Проблеск надежды",[4283]="ПЯТЬДЕСЯТ! АГА!",
    [4284]="Кристаллы силы",[4285]="Северный пилон",[4286]="Хороший товар",[4287]="Восточный пилон",
    [4288]="Западный пилон",[4289]="Обезьяны Ун'Горо",[4290]="Добыча Лар'корви",[4291]="Запах Лар'корви",
    [4292]="Приманка для Лар'корви",[4293]="Проба слизи...",[4294]="...и образцы слизнюков",
    [4295]="Эль для Каменного Узла",[4296]="Табличка Семерых",[4297]="Покормить малыша",
    [4298]="У вас появился малыш!",[4300]="Костяные клинки",[4301]="Могучая Уча",[4321]="Давай-ка разберемся",
    [4322]="Побег!",[4324]="Юка Крутипроб",[4341]="Каран Могучий Молот",[4342]="Рассказ Карана",
    [4343]="Оскверненный ветроцвет",[4361]="Недобрые вести",[4362]="Судьба королевства",[4363]="Королевский сюрприз",
    [4381]="Кристалл восстановления",[4382]="Кристалл силы духа",[4383]="Кристалл-хранитель",
    [4384]="Хрустальный удар",[4385]="Хрустальный заряд",[4386]="Хрустальная спираль",[4401]="Оскверненный песнецвет",
    [4402]="Кактусовый десерт Галгара",[4403]="Оскверненный ветроцвет",[4421]="Порча нефритового огня",
    [4441]="Древа в узах скверны",[4442]="Очищение явлено!",[4443]="Оскверненный кнутокорень",
    [4444]="Оскверненный кнутокорень",[4445]="Оскверненный кнутокорень",[4446]="Оскверненный кнутокорень",
    [4447]="Оскверненный ночной дракон",[4448]="Оскверненный ночной дракон",[4449]="Попался!",
    [4450]="Учетная книга из Танариса",[4451]="Ключ к свободе",[4461]="Оскверненный кнутокорень",
    [4462]="Оскверненный ночной дракон",[4463]="Манускрипт Размышления",[4464]="Оскверненный песнецвет",
    [4465]="Оскверненный песнецвет",[4466]="Оскверненный ветроцвет",[4467]="Оскверненный ветроцвет",
    [4481]="Манускрипт Здоровья",[4482]="Манускрипт Упорства",[4483]="Манускрипт Устойчивости",
    [4490]="Призывание коня Скверны",[4491]="Дружеская помощь",[4492]="Потерялся!",[4493]="Нашествие силитидов",
    [4494]="Нашествие силитидов",[4495]="Добрый друг",[4496]="Путаница в джунглях",
    [4501]="Осторожно, злой терродактиль",[4502]="Вулканическая активность",[4503]="Крылолет Шиззла",
    [4504]="Суперлипучка",[4505]="Источник порчи",[4506]="Зараженные саблезубы",[4507]="Пешка берет королеву",
    [4508]="Затишье перед бурей",[4509]="Затишье перед бурей",[4510]="Затишье перед бурей",
    [4511]="Затишье перед бурей",[4512]="Долгий путь слизнюка",[4513]="Долгий путь слизнюка",
    [4521]="Одичавшие стражи",[4542]="Письмо на Заставу Вольного Ветра",[4561]="Образцы на пробу из кратера Ун'Горо",
    [4581]="Кайнет Штиль",[4601]="Чистер 5200!",[4602]="Чистер 5200!",[4603]="Работа для Чистера",
    [4604]="Работа для Чистера",[4605]="Чистер 5200!",[4606]="Чистер 5200!",[4621]="Стой, Адмирал!",
    [4641]="Твое место в мире",[4642]="Слияние",[4661]="Проба – образцы из Оскверненного леса",
    [4681]="Останки на берегу",[4701]="Устранение опасности",[4721]="Одичавшие стражи",
    [4722]="Останки морской черепахи",[4723]="Останки морской твари",[4724]="Праматерь стаи",
    [4725]="Останки морской черепахи",[4726]="Сущность детеныша дракона",[4727]="Останки морской черепахи",
    [4728]="Останки морской твари",[4729]="Редкие звери Киблера",[4730]="Останки морской твари",
    [4731]="Останки морской черепахи",[4732]="Останки морской черепахи",[4733]="Останки морской твари",
    [4734]="Заморозка яйца",[4739]="Поиски Менары Расщепительницы Бездны",[4740]="Разыскивается: Глубомрак!",
    [4741]="Одичавшие стражи",[4742]="Печать Вознесения",[4743]="Печать Вознесения",[4761]="Тандрис Ветропряд",
    [4762]="Река Скалистая",[4763]="Порабощенные фурболги Чернолесья",[4764]="Пряжка Роковой оснастки",
    [4765]="Доставить Риджвеллу",[4766]="Майра Светлое Крыло",[4767]="Ветрокрыл",[4768]="Табличка Темнокамня",
    [4769]="Вивиан Лягроб и табличка Темнокамня",[4770]="Путь домой",[4786]="Завершенное одеяние",
    [4787]="Древнее яйцо",[4788]="Последние таблички",[4801]="Э'ко ледопардов",
    [4802]="Э'ко фурболгов племени Зимней Спячки",[4803]="Э'ко щербозубов",[4804]="Э'ко хладнокрылов",
    [4805]="Э'ко йети",[4806]="Э'ко великанов",[4807]="Э'ко диких совухов",[4808]="Фелнок Сталлист",
    [4809]="Рога хладнокрылов",[4810]="Возвращение к Тинки",[4811]="Красный кристалл",[4812]="Пока струится вода...",
    [4813]="Скрытые фрагменты",[4822]="Женщинам – цветы, детям – ...",[4841]="Упокоение кентавров",
    [4842]="Выяснение причин",[4861]="Взбесившиеся дикие совухи",[4862]="Товар на любителя",
    [4863]="Взбесившиеся дикие совухи",[4864]="Взбесившиеся дикие совухи",[4865]="Змеиная дикость",
    [4866]="Материнское молоко",[4867]="Аррок Смертный Вопль",[4881]="Убийственный заговор",
    [4882]="Умение хранить секреты",[4883]="Умение хранить секреты",[4901]="Стражи алтаря",[4902]="Питомцы Элуны",
    [4903]="Приказ полководца",[4904]="Долгожданная свобода",[4906]="Снова порча!",[4907]="Тинки Кипеллер",
    [4921]="Пропавшая без вести",[4965]="Знание шара Орахила",[4969]="Знание шара Орахила",
    [4970]="Накормить ледопардов",[4971]="Вопрос времени",[4972]="Отсчет времени",[4973]="Отсчет времени",
    [4976]="Возвращение к Менаре",[4981]="Агент Блестяшка",[4982]="Вещи Блестяшки",[4983]="По данным разведки",
    [4984]="Страдания природы",[4985]="Страдания природы",[4986]="Покрытая письменами дубовая ветвь",
    [4987]="Покрытая письменами дубовая ветвь",[5001]="Вещи Блестяшки",[5002]="Донесение Максвелла",
    [5021]="Лучше поздно, чем никогда",[5022]="Лучше поздно, чем никогда",[5023]="Лучше поздно, чем никогда",
    [5041]="Снабжение Перекрестка",[5042]="Сила Агамаггана",[5043]="Ловкость Агамаггана",[5044]="Мудрость Агамаггана",
    [5045]="Высокий дух",[5046]="Иглошкура",[5047]="Пип Шустрикс, к вашим услугам!",[5048]="Добросердечная Эмма",
    [5049]="Грусть Иеремии",[5050]="Оберег удачи",[5051]="Вторая половина",[5052]="Кровавые осколки Агамаггана",
    [5054]="Урсиус из щербозубов",[5055]="Хладнокрылая Брумеран",[5056]="Ши-Ротам",[5057]="Прежние свершения",
    [5058]="Дневник миссис Далсон",[5059]="Под замком",[5061]="Водный облик",[5062]="Священное пламя",
    [5063]="Шапка ученого из Алого ордена",[5064]="Наблюдение за Зловещим Тотемом",
    [5065]="Утраченные таблички Мошару",[5066]="Призыв к оружию: Чумные земли!",[5067]="Поножи тайны",
    [5068]="Кираса кровавой жажды",[5081]="Миссия Максвелла",[5082]="Угроза со стороны Зимней Спячки",
    [5083]="Огненный эликсир Зимнего Сна",[5084]="Поддавшиеся порче",[5085]="Таинственная слизь",
    [5086]="Ядовитый Ужас",[5087]="Гонцы Зимней Спячки",[5088]="Арикара",[5089]="Приказ генерала Драккисата",
    [5090]="Призыв к оружию: Чумные земли!",[5091]="Призыв к оружию: Чумные земли!",[5092]="Зачистка территории",
    [5093]="Призыв к оружию: Чумные земли!",[5094]="Призыв к оружию: Чумные земли!",
    [5095]="Призыв к оружию: Чумные земли!",[5096]="Вылазка в стан Алого ордена",[5097]="Сторожевые башни",
    [5101]="Великое тестовое задание... Судьбы!",[5103]="Смерть в огне",
    [5121]="Верховный вождь племени Зимней Спячки",[5122]="Медальон веры",[5123]="Последний фрагмент мозаики",
    [5124]="Огненные латные рукавицы",[5125]="Слова Аурия",[5126]="История Лоракса",[5127]="Демонова кузня",
    [5141]="Кожевничество: чешуя дракона",[5146]="Кожевничество: сила стихий",
    [5148]="Кожевничество: традиции предков",[5149]="Кукла Памелы",[5150]="Даданга проголодалась!",
    [5151]="Механизм гипервместимости",[5152]="Тетушка Марлен",[5153]="Странный историк",[5154]="Анналы Дарроушира",
    [5155]="Силы Джеденара",[5156]="Проверка на порчу",[5157]="Собрать оскверненную воду",
    [5158]="В поисках духовной помощи",[5159]="Чистая вода возвращается в Оскверненный лес",
    [5160]="Матрона-защитница",[5161]="Гнев синих драконов",[5162]="Гнев синих драконов",[5163]="Йети где-то рядом…",
    [5164]="Перечень Заблудших",[5165]="Погасить Пламя Защиты",[5166]="Кираса Всецветных драконов",
    [5167]="Ножные латы всецветного воина",[5168]="Герои Дарроушира",[5181]="Негодяи Дарроушира",
    [5201]="Вторжение племени Зимней Спячки",[5202]="Странный красный ключ",[5203]="Спасение из Джеденара",
    [5204]="Воздаяние Света",[5206]="Мародеры Дарроушира",[5210]="Брат Карлин",[5211]="Защитники Дарроушира",
    [5212]="Плоть не лжет",[5213]="Вирус чумы",[5214]="Великий Эзра Гримм",[5215]="Котлы Плети",
    [5216]="Цель: поле Джанис",[5217]="Возвращение в Лагерь Промозглого Ветра",[5218]="Котел поля Джанис",
    [5219]="Цель: Слезы Далсона",[5220]="Возвращение в Лагерь Промозглого Ветра",[5221]="Котел Слез Далсона",
    [5222]="Цель: Удел Страданий",[5223]="Возвращение в лагерь Промозглого Ветра",[5224]="Котел Удела Страданий",
    [5225]="Цель: пустошь Гаррона",[5226]="Возвращение в лагерь Промозглого Ветра",[5227]="Котел пустоши Гаррона",
    [5228]="Котлы Плети",[5229]="Цель: поле Джанис",[5230]="Возвращение в Бастион",[5231]="Цель: Слезы Далсона",
    [5232]="Возвращение в Бастион",[5233]="Цель: Удел Страданий",[5234]="Возвращение в Бастион",
    [5235]="Цель: пустошь Гаррона",[5236]="Возвращение в Бастион",[5237]="Задание выполнено!",
    [5238]="Задание выполнено!",[5241]="Дядюшка Карлин",[5242]="Окончательный удар",[5243]="Святая вода",
    [5244]="Руины Кел'Терила",[5245]="Беспокойные духи Кел'Терила",[5246]="Фрагменты прошлого",
    [5247]="Фрагменты прошлого",[5248]="Измученный воспоминаниями о прошлом",[5249]="В Зимние Ключи!",
    [5250]="Звездопад",[5251]="Архивариус",[5252]="Раскаявшийся высокорожденный",[5253]="Кристалл Зин-Малора",
    [5261]="Иган Меховщик",[5262]="Ошеломляющая истина",[5263]="Быстрее, выше, сильнее",[5264]="Лорд Максвелл Тиросс",
    [5265]="Серебряный Оплот",[5281]="Мятущиеся души",[5307]="Порча",[5321]="Спящий пробудился",
    [5341]="Сокровище Баровых",[5342]="Последний из Баровых",[5343]="Сокровище Баровых",[5344]="Последний из Баровых",
    [5361]="Семейное древо",[5381]="Рука Ируксоса",[5382]="Доктор Теолен Крастинов – Мясник",
    [5383]="Мешок ужасов Крастинова",[5384]="Киртонос Глашатай",[5385]="Останки Трея Светогорна",
    [5386]="Дорога рыбка к обеду",[5401]="Жетон Серебряного Рассвета",[5402]="Камни приспешников плети",
    [5403]="Камни захватчиков Плети",[5404]="Камни осквернителей Плети",[5405]="Жетон Серебряного Рассвета",
    [5406]="Камни осквернителей Плети",[5407]="Камни захватчиков Плети",[5408]="Камни приспешников плети",
    [5421]="Рыбка в ведерке",[5441]="Ленивые батраки",[5461]="Рас Ледяной Шепот – человек",
    [5462]="Рас Ледяной Шепот – гибель",[5463]="Дар Менетила",[5464]="Дар Менетила",[5465]="Книга Души",
    [5466]="Рас Ледяной Шепот – лич",[5481]="Задание Толстяка",[5482]="Погибельник",[5502]="Опекун Орды",
    [5503]="Жетон Серебряного Рассвета",[5504]="Оплечья Рассвета",[5505]="Ключ от Некроситета",
    [5507]="Оплечья Рассвета",[5508]="Камни осквернителей Плети",[5509]="Камни захватчиков Плети",
    [5510]="Камни приспешников плети",[5511]="Ключ от Некроситета",[5513]="Оплечья Рассвета",
    [5514]="Форма денег стоит",[5515]="Мешок ужасов Крастинова",[5517]="Многоцветная драгоценность Рассвета",
    [5518]="Броня огров Гордока",[5519]="Броня огров Гордока",[5521]="Многоцветная драгоценность Рассвета",
    [5522]="Леонид Барталомей",[5524]="Многоцветная драгоценность Рассвета",[5525]="Освободите Нотта!",
    [5526]="Осколки сквернита",[5527]="Реликварий Чистоты",[5528]="Лучшее пойло Гордока",
    [5529]="Зачумленные детеныши дракона",[5531]="Бетина Биггльцинк",[5533]="Некроситет",
    [5534]="\"Пропавшее\"оборудование Ким'джаеля",[5535]="Беспокойные духи",[5536]="Земли, полные ненависти",
    [5537]="Фрагменты скелетов",[5538]="Форма денег стоит",[5541]="Боеприпасы для Громострела",[5542]="Псы-демоны",
    [5543]="Окровавленные небеса",[5544]="Мясо личинок-трупоедов",[5545]="Тридцать три несчастья",[5561]="Отлов кодо",
    [5581]="Порталы Легиона",[5582]="Здоровая чешуя дракона",[5680]="Страж Тьмы",[5713]="Каждый выстрел – в цель",
    [5721]="Битва при Дарроушире",[5722]="В поисках потерянного ранца",[5723]="Испытание силы врага",
    [5724]="Возвращение потерянной сумки",[5725]="The Power to Destroy...",[5726]="Тайные враги",
    [5727]="Тайные враги",[5728]="Тайные враги",[5729]="Тайные враги",[5730]="Тайные враги",[5741]="Скипетр Света",
    [5742]="Искупление",[5761]="Убить тварь",[5762]="Хеминг Эрнестуэй-младший",[5763]="Охота в Тернистой долине",
    [5781]="Символ ушедших дней",[5801]="Кузня Пламенного хребта",[5802]="Кузня Пламенного хребта",
    [5803]="Скарабей Аража",[5804]="Скарабей Аража",[5805]="Привет!",[5821]="Наемный телохранитель",[5841]="Привет!",
    [5842]="Привет!",[5843]="Привет!",[5844]="Привет!",[5845]="Символ утраченной чести",
    [5846]="Символ семейной любви",[5847]="Привет!",[5848]="Символ семейной любви",[5861]="Найти Миранду",
    [5862]="Уловка против Алого ордена",[5863]="Поселение Песчаного Молота",[5881]="Смена караула",
    [5882]="Лекарство из охотничьих трофеев",[5883]="Лекарство из минералов",[5884]="Лекарство из оскверненных трав",
    [5885]="Лекарство из оскверненных шкур",[5886]="Лекарство из распыленных предметов",
    [5887]="Лекарство из охотничьих трофеев",[5888]="Лекарство из минералов",[5889]="Лекарство из оскверненных трав",
    [5890]="Лекарство из оскверненных шкур",[5891]="Лекарство из распыленных предметов",
    [5892]="Припасы Железного рудника",[5893]="Припасы из рудника Ледяного Зуба",[5901]="Чума на вашу лесопилку!",
    [5902]="Чума на вашу лесопилку!",[5903]="Чума на вашу лесопилку!",[5932]="Возвращение в Громовой Утес",
    [5941]="Возвращение к Хроми",[5942]="Спрятанные сокровища",[5943]="Караван Гизлтона",[5944]="Во сне",
    [5961]="Защитник королевы банши",[6002]="Тело и дух",[6004]="Неоконченное дело",[6021]="Зельдарр Изгой",
    [6022]="Преднамеренное убийство",[6023]="Неоконченное дело",[6024]="Мольба Хамейи",[6025]="Неоконченное дело",
    [6026]="Работу пополам",[6027]="Книга Древних",[6028]="Донесение из Круговзора",[6029]="Донесение из Круговзора",
    [6030]="Герцог Николас Зверенхофф",[6031]="Руническая ткань",[6032]="Священная ткань",[6041]="Дымок над водою",
    [6130]="Власть над ядом",[6131]="Союзник Древобрюхов",[6132]="Вытащи меня отсюда!",[6133]="Охота на cледопытов",
    [6134]="Сбор эктоплазмы",[6135]="Проклятый Тенекрыл",[6136]="Огромный червь",[6141]="Брат Антон",
    [6142]="Наживка из моллюска",[6143]="Смерть земноводным!",[6144]="Приказ по армии",
    [6145]="Курьер из Багрового Легиона",[6146]="Уловка Натаноса",[6147]="Назад к Натаносу",
    [6148]="Алый Оракул Деметрия",[6161]="Сокровища Ракмора",[6162]="Последняя битва супруга",[6163]="Рамштайн",
    [6164]="Книга рецептов Августа",[6181]="Срочное сообщение",[6182]="Первый и последний",
    [6183]="Поминовение усопших",[6184]="Флинт Тенемор",[6185]="Чума на востоке",[6186]="Пришествие Гнилостеня",
    [6187]="Порядок должен быть восстановлен",[6221]="Северные фурболги Мертвого Леса",
    [6241]="Боевые действия в деревне Зимней Спячки",[6261]="Дунгар Долгопив",[6281]="Продолжение пути в Штормград",
    [6282]="Угроза со стороны гарпий",[6283]="Предводительница стаи Кровавой Ярости",[6284]="Арахнофобия",
    [6285]="Возвращение к Льюису",[6301]="Цикл возрождения",[6321]="Поставка оружия",[6322]="Майкл Гарретт",
    [6323]="Полет в Подгород",[6324]="Обратно к Подригу",[6341]="Изобилие Тельдрассила",[6342]="Полет в Аубердин",
    [6343]="Возвращение к Нессе",[6344]="Несса Песнь Теней",[6361]="Связка шкур",[6362]="Дорога до Громового Утеса",
    [6363]="Укротитель ветрокрылов Тал",[6364]="Возвращение к Джахану",[6365]="Мясные продукты в Оргриммар",
    [6381]="Новая жизнь",[6382]="Большая охота",[6383]="Большая охота",[6384]="Дорога до Оргриммара",
    [6385]="Укротитель ветрокрылов Дорас",[6386]="Возвращение на Перекресток",[6387]="Награды ученикам",
    [6388]="Грит Турден",[6389]="Чума на вашу лесопилку!",[6390]="Чума на вашу лесопилку!",[6391]="Полет в Стальгорн",
    [6392]="Возвращение к Броку",[6393]="Война элементалей",[6394]="Кирка Тазз'рила",[6395]="Последнее желание Марлы",
    [6401]="Кайя жива!",[6402]="Встреча в Штормграде",[6403]="Великий Маскарад",[6421]="Ущелье Камнепадов",
    [6441]="Рога сатира",[6442]="Наги на Зорамском взморье",[6461]="Кровопийцы",[6462]="Оберег троллей",
    [6481]="Пробуждение земельника",[6482]="Свободу Руулу!",[6501]="Око дракона",[6502]="Амулет Пламени дракона",
    [6503]="Вестницы Ясеневого леса",[6504]="Утраченные страницы",[6521]="Нечестивый союз",[6522]="Нечестивый союз",
    [6523]="Защита Кайи",[6541]="Донесение Кадраку",[6542]="Донесение Кадраку",[6543]="Отчет клана Песни Войны",
    [6544]="Налет Торека",[6545]="Сведения гонца из клана Песни Войны",
    [6546]="Сведения всадника из клана Песни Войны",[6547]="Сведения разведчика из клана Песни Войны",
    [6548]="Отомсти за мою деревню",[6561]="Злодейство в Непроглядной Пучине",[6562]="Угроза из Глубин",
    [6563]="Сущность Аку'май",[6564]="Верность Древним богам",[6565]="Верность Древним богам",
    [6566]="Что принес ветер",[6567]="Герой Орды",[6568]="Мастерица обмана",[6569]="Иллюзии Ока",[6570]="Огнебор",
    [6571]="Поставка для клана Песни Войны",[6581]="Пилы клана Песни Войны",[6582]="Черепа: Провидец",
    [6583]="Черепа: Сомнус",[6584]="Черепа: Хроналис",[6585]="Черепа: Акстроз",[6601]="Вознесение",
    [6602]="Кровь могучего черного дракона",[6603]="Сложности в Зимних ключах!",[6604]="Взбесившиеся дикие совухи",
    [6605]="Странная дамочка",[6612]="Я знаю одного парня...",[6625]="Травматологи Альянса",[6626]="Воинство зла",
    [6627]="Испытание знаний",[6628]="Испытание знаний",[6629]="Убить Грундига Темное Облако",
    [6641]="Ворша Хлестунья",[6642]="Покровительство братства, черное железо",
    [6643]="Покровительство братства, огненное ядро",[6644]="Покровительство братства, ядро лавы",
    [6645]="Покровительство братства, кожа Недр",[6646]="Покровительство братства, кровь горы",[6661]="Охота на крыс",
    [6701]="Эмблемы Синдиката",[6721]="Путь охотника",[6722]="Путь охотника",[6741]="Больше добычи!",
    [6761]="Новое пограничье",[6762]="Рабин Сатурна",[6781]="Больше обломков брони",[6801]="Локолар Владыка Льда",
    [6804]="Отравленная вода",[6805]="Буря в пустыне",[6821]="Око Углевзора",[6822]="Огненные Недра",
    [6823]="Агент Гидраксиса",[6824]="Руки врага",[6825]="Небо зовет – флот Смуггла",[6826]="Небо зовет – флот Мааши",
    [6827]="Воздух зовет – флот Маэстра",[6844]="Умбер, архивариус",[6845]="Раскрытие древних секретов",
    [6846]="В атаку!",[6847]="Всевидящее око мастера Рисона",[6848]="Всевидящее око мастера Рисона",
    [6861]="Портативный крошшер Зинфиззлекса",[6862]="Портативный крошшер Зинфиззлекса",
    [6881]="Ивус Лесной Властелин",[6901]="В атаку!",[6921]="Среди руин",[6922]="Барон Акванис",
    [6941]="Небо зовет – флот Змейера",[6942]="Небо зовет – флот Слидора",[6964]="Повод для праздника",
    [6981]="Светящийся осколок",[6984]="\"Пастбища Дымного Леса\" благодарны тебе!",
    [6985]="Припасы Железного рудника",[7001]="Пустые стойла",[7002]="Упряжь из бараньей кожи",
    [7025]="Угощение для Дедушки Зимы",[7026]="Упряжь ездовых баранов",[7027]="Пустые стойла",
    [7028]="Хрустальные орнаменты",[7029]="Порча Злоязыкого",[7043]="Прохладное чувство юмора",
    [7045]="\"Пастбища Дымного Леса\" благодарны тебе!",[7063]="Пир Зимнего покрова",[7064]="Яблочко от яблоньки...",
    [7065]="Яблочко от яблоньки...",[7066]="Семя Жизни",[7067]="Инструкции кентавра-парии",
    [7068]="Фрагменты осколка сумрака",[7070]="Фрагменты осколка сумрака",[7081]="Кладбища Альтеракской долины",
    [7082]="Кладбища долины Альтерака",[7101]="Башни и бункеры",[7102]="Башни и бункеры",[7121]="Интендант",
    [7122]="Захват рудника",[7123]="Разговор с интендантом",[7124]="Захват рудника",[7141]="Битва за Альтерак",
    [7142]="Битва за Альтерак",[7161]="Испытательные земли",[7162]="Испытательные земли",
    [7163]="Награда найдет героя",[7164]="Уважение клана",[7165]="Заслуженное почтение",[7166]="Легендарные герои",
    [7167]="Око Командования",[7168]="Награда найдет героя",[7169]="Уважение Стражи",[7170]="Заслуженное почтение",
    [7171]="Легендарные герои",[7172]="Око Командования",[7181]="Легенда о Корраке",[7201]="Последний элемент",
    [7202]="Коррак Кровопуск",[7221]="Разговор с геологом Камнетеркой",[7222]="Разговор с Воггой Смертобоем",
    [7223]="Обломки брони",[7224]="Вражеский трофей",[7241]="Защита клана Северного Волка",[7261]="Королевское право",
    [7281]="Братская любовь",[7282]="Братская любовь",[7301]="Свергнутые властители небес",
    [7321]="Нежный черепаховый суп",[7341]="Честная сделка",[7342]="Стрелы – для неженок!",
    [7367]="Обезвредить угрозу",[7368]="Обезвредить угрозу",[7383]="Венец Земли",[7385]="Галлон крови",
    [7386]="Гроздь кристаллов",[7429]="Освободите Нотта!",[7441]="Пузиллин и старейшина Аж'Тордин",
    [7461]="Древнее безумие",[7462]="Сокровище Шен'драларов",[7463]="Магический напиток",[7481]="Эльфийские легенды",
    [7482]="Эльфийские легенды",[7483]="Манускрипт Скорости",[7484]="Манускрипт Средоточия",
    [7485]="Манускрипт Защиты",[7486]="Награда для героя",[7487]="Сродство с недрами",[7488]="Сеть Лефтендрис",
    [7489]="Сеть Лефтендрис",[7490]="Победа Орды",[7491]="На виду у всех",[7492]="Лагерь Мохаче",
    [7493]="Все еще только начинается!",[7494]="Крепость Оперенной Луны",[7495]="Славная победа Альянса",
    [7496]="Праздник добрых времен",[7497]="Все еще только начинается!",
    [7498]="Гарона: Исследование уловок и предательства",[7499]="Кодекс Обороны",[7500]="Поваренная книга чародея",
    [7501]="Свет и как его раскачать",[7502]="Укрощая тени",[7503]="Величайшая гонка охотников",
    [7504]="Святая Болонья: О чем не говорит Свет",[7505]="Ледяной шок и вы",[7506]="Изумрудный Сон",
    [7507]="Nostro's Compendium",[7508]="Ковка Кель-Серрара",[7509]="The Forging of Quel'Serrar",
    [7603]="Огненное ядро Крошиуса",[7659]="Имперские латные наплечники",[7660]="Обмен волками – полярный волк",
    [7661]="Обмен волками – красный волк",[7662]="Новый кодо – бирюзовый",[7663]="Новый кодо – зеленый",
    [7664]="Новый бежевый ящер",[7670]="Лорд Грейсон Тенелом",[7671]="Новый ледопард",[7672]="Новый ночной саблезуб",
    [7673]="Замена снежного барана",[7674]="Замена черного барана",[7675]="Замена синего механодолгонога",
    [7676]="Замена белого механодолгонога",[7677]="Белый жеребец",[7678]="Игреневый конь",[7681]="Hunter test quest",
    [7682]="Hunter test quest2",[7701]="Разыскивается: надзиратель Мальториус",[7702]="Казнь через лишение сна",
    [7703]="Неоконченное дело Гордоков",[7704]="Размер имеет значение",[7721]="Энергия для уменьшения",
    [7722]="Какой еще плавень?",[7723]="Отекшие пальцы",[7724]="Огненная угроза",[7725]="Еще раз ослабим великанов",
    [7726]="Новая энергия для уменьшения",[7727]="Пламезавры? Ну и название...",
    [7728]="УКРАДЕНО: фурма и подзорная труба наблюдателя",[7729]="ВАКАНСИЯ: устранитель конкурентов",
    [7730]="Вторжение улья Цуккаш",[7731]="Жалохвост",[7732]="Донесение об улье Зукк'аш",[7733]="Борьба за качество",
    [7734]="Борьба за качество",[7735]="Безупречная шкура йети",
    [7736]="Пополнение запасов огненного плавня – королевская кровь",[7737]="Завоевать еще большую благосклонность",
    [7738]="Безупречная шкура йети",[7761]="Приказ Чернорука",[7781]="Владыка Черной горы",
    [7782]="Владыка Черной горы",[7783]="Владыка Черной горы",[7787]="Громовая ярость",[7788]="Долой захватчиков!",
    [7789]="Громи захватчиков-Среброкрылых!",[7791]="Пожертвование – шерсть",[7792]="Пожертвование: шерсть",
    [7793]="Пожертвование – шелк",[7794]="Пожертвование – магическая ткань",[7795]="Пожертвование: руническая ткань",
    [7796]="Больше рунической ткани",[7797]="Пространственный проходчик - Круговзор",[7798]="Пожертвование: шелк",
    [7799]="Пожертвование: магическая ткань",[7800]="Пожертвование: руническая ткань",
    [7801]="Больше рунической ткани",[7802]="Пожертвование: шерсть",[7803]="Пожертвование: шелк",
    [7804]="Пожертвование: магическая ткань",[7805]="Пожертвование: руническая ткань",
    [7806]="Больше рунической ткани",[7807]="Пожертвование: шерсть",[7808]="Пожертвование: шелк",
    [7809]="Пожертвование: магическая ткань",[7810]="Повелитель арены",[7811]="Пожертвование: руническая ткань",
    [7812]="Больше рунической ткани",[7813]="Пожертвование: шерсть",[7814]="Пожертвование: шелк",
    [7815]="Хрустогрызы, чувак!",[7816]="Гаммерита!",[7817]="Пожертвование: магическая ткань",
    [7818]="Пожертвование: руническая ткань",[7819]="Больше рунической ткани",[7820]="Пожертвование: шерсть",
    [7821]="Пожертвование: шелк",[7822]="Пожертвование: магическая ткань",[7823]="Пожертвование: руническая ткань",
    [7824]="Пожертвование: руническая ткань",[7825]="Больше рунической ткани",[7826]="Пожертвование: шерсть",
    [7827]="Пожертвование: шелк",[7828]="Охота на бродяг",[7829]="Охота на дикарей",[7830]="Отмщение за погибших",
    [7831]="Пожертвование: магическая ткань",[7832]="Больше рунической ткани",[7833]="Пожертвование: шерсть",
    [7834]="Пожертвование: шелк",[7835]="Пожертвование: магическая ткань",[7836]="Пожертвование: руническая ткань",
    [7837]="Больше рунической ткани",[7838]="Великий повелитель арены",[7839]="Хулиганы из племени Порочной Ветви",
    [7840]="Лярд потерял свой обед",[7841]="Послание для Громового Молота",
    [7842]="Еще одно послание для Громового Молота",[7843]="Последнее послание для Громового Молота",
    [7844]="Собратья-каннибалы",[7845]="Похищен старейшина Зазубренный Клык!",[7846]="Отыскать ключ!",
    [7847]="Возвращение к старейшине Зазубренный Клык",[7848]="Сродство с недрами",[7849]="Воссоединение останков",
    [7850]="Темные сосуды",[7861]="Разыскивается: коварная жрица Ведьмиса и ее прислужники",
    [7862]="Требуется: капитан стражи в деревню Сломанного Клыка",[7863]="Припасы часовых",
    [7864]="Стандартные припасы часового",[7865]="Улусшенные припасы часового",[7866]="Припасы Всадников",
    [7867]="Стандартные припасы Всадников",[7868]="Улучшенные припасы Всадников",[7871]="Долой захватчиков!",
    [7872]="Долой захватчиков!",[7873]="Долой захватчиков!",[7874]="Громи захватчиков-Среброкрылых!",
    [7875]="Громи захватчиков-Среброкрылых!",[7876]="Громи захватчиков-Среброкрылых!",
    [7903]="Глаза злобных летучих мышей",[7907]="Карты Новолуния: Звери",[7908]="Повелитель арены",
    [7946]="Потомство Жабжаб",[7981]="1200 билетов – амулет Новолуния",[8021]="Призовой купон АйКока",
    [8023]="Призовой купон АйКока",[8026]="Призовой купон АйКока",[8041]="Сила горы Мугамба",
    [8042]="Сила горы Мугамба",[8043]="Сила горы Мугамба",[8044]="Ярость Мугамбы",[8045]="Клеймо язычника",
    [8046]="Клеймо язычника",[8047]="Клеймо язычника",[8048]="Печать героя",[8049]="Око Зулдазара",
    [8050]="Око Зулдазара",[8051]="Око Зулдазара",[8052]="Всевидящее Око Зулдазара",
    [8053]="Знаки Силы: боевые наручи вольнодумца",[8054]="Знаки силы: пояс вольнодумца",
    [8055]="Знаки Силы: кираса вольнодумца",[8056]="Знаки Силы: наручи авгура",[8057]="Знаки Силы: наручи гаруспика",
    [8058]="Знаки Силы: боевые наручи воздаятеля",[8059]="Знаки Силы: напульсники бесноватого",
    [8060]="Знаки Силы: напульсники мастера иллюзий",[8061]="Знаки Силы: напульсники исповедника",
    [8062]="Знаки Силы: наручи хищника",[8063]="Знаки Силы: наручи безумца",[8064]="Знаки Силы: пояс гаруспика",
    [8065]="Знаки Силы: мундир гаруспика",[8066]="Знаки Силы: пояс хищника",[8067]="Знаки Силы: оплечье хищника",
    [8068]="Знаки Силы: оплечье мастера иллюзий",[8069]="Знаки Силы: одеяние мастера иллюзий",
    [8070]="Знаки Силы: пояс исповедника",[8071]="Знаки Силы: оплечье исповедника",
    [8072]="Знаки Силы: оплечье безумца",[8073]="Знаки Силы: мундир безумца",[8074]="Знаки Силы: пояс авгура",
    [8075]="Знаки Силы: хауберк авгура",[8076]="Знаки Силы: оплечье бесноватого",
    [8077]="Знаки Силы: одеяние бесноватого",[8078]="Знаки Силы: пояс воздаятеля",
    [8079]="Знаки Силы: кираса воздаятеля",[8080]="Ресурсы Низины Арати",[8101]="Камешек Каджаро",
    [8102]="Камешек Каджаро",[8103]="Камешек Каджаро",[8104]="Самоцвет Каджаро",[8105]="Битва за Низину Арати",
    [8106]="Ожерелье Кезанского порока",[8107]="Ожерелье Кезанского порока",[8108]="Ожерелье Кезанского порока",
    [8109]="Ожерелье вечного Кезанского порока",[8110]="Зачарованные водоросли Южных морей",
    [8111]="Зачарованные водоросли Южных морей",[8112]="Зачарованные водоросли Южных морей",
    [8113]="Безупречные зачарованные водоросли Южных морей",[8114]="Контроль над четырьмя базами",
    [8115]="Контроль над пятью базами",[8116]="Ожерелье видений Вудресса",[8117]="Ожерелье видений Вудресса",
    [8118]="Ожерелье видений Вудресса",[8119]="Незамутненное ожерелье видений Вудресса",
    [8120]="Битва за Низину Арати",[8121]="Захват четырех баз",[8122]="Занять пять баз",
    [8123]="Перекрыть линии поставок Аратора",[8141]="Зандаларский талисман тени",[8142]="Зандаларский талисман тени",
    [8143]="Зандаларский талисман тени",[8144]="Зандаларский талисман власти над тенями",[8145]="Нить Водоворота",
    [8146]="Нить Водоворота",[8147]="Нить Водоворота",[8153]="Рога и копыта",[8154]="Ресурсы Низины Арати",
    [8155]="Ресурсы Низины Арати",[8156]="Ресурсы Низины Арати",[8160]="Перекрыть линии поставок Аратора",
    [8161]="Перекрыть линии поставок Аратора",[8162]="Перекрыть линии поставок Аратора",
    [8166]="Битва за Низину Арати",[8167]="Битва за Низину Арати",[8168]="Битва за Низину Арати",
    [8169]="Битва за Низину Арати",[8170]="Битва за Низину Арати",[8171]="Битва за Низину Арати",
    [8181]="Сопротивление Йекинье",[8182]="Длань Растахана",[8183]="Сердце Хаккара",[8184]="Явление Силы",
    [8185]="Печать синкретиста",[8186]="Объятия Смерти",[8187]="Зов Сокола",[8188]="Неусыпные узы вуду",
    [8189]="Явление прозрения",[8190]="Наговор худу",[8191]="Пророческая аура",[8194]="Начинающий рыболов",
    [8195]="Монеты племен Зулиан, Раззаши и Хаккари",[8196]="Экстракт манго",
    [8225]="Редкая рыба – синий полосатик Браунелла",[8227]="Измерительная лента Ната",
    [8228]="Приглашение на рыбалку",[8236]="Лазурный ключ",
    [8238]="Монеты племен Гурубаши, Порочной Ветви и Сухокожих",
    [8239]="Монеты племен: Песчаная Буря, Дробители Черепов и Кровавый Скальп",[8240]="Драгоценности для Занзы",
    [8241]="Пополнение запасов огненного плавня - железо",
    [8242]="Пополнить запасы огненного плавня с помощью толстой кожи",[8243]="Напиток могущества Занзы",
    [8259]="Более достойная награда",[8260]="Полевой комплект Лиги Аратора",
    [8261]="Стандартный полевой комплект Лиги Аратора",[8262]="Улучшенный полевой комплект Лиги Аратора",
    [8263]="Полевой комплект Осквернителей",[8264]="Стандартный полевой комплект Осквернителей",
    [8265]="Улучшенный полевой комплект Осквернителей",[8266]="Ленты жертвоприношения",
    [8268]="Ленты жертвоприношения",[8271]="Герой клана Грозовой Вершины",[8272]="Герой клана Северного Волка",
    [8273]="Благодарность Оран",[8275]="Отвоевание Силитуса",[8276]="Отвоевание Силитуса",[8277]="Смертельный яд",
    [8278]="Последняя надежда Ноггла",[8279]="Сумеречный словарь",[8280]="Надежные поставки",
    [8281]="Обеспечение безопасности",[8282]="Потерянная сумка Ноггла",[8283]="РОЗЫСК: Смертехват, гроза пустыни",
    [8284]="Сумеречная тайна",[8285]="Дезертир",[8286]="Что ждет нас завтра",[8287]="Ужасная цель",
    [8288]="Кто будет избран?",[8290]="Долой захватчиков!",[8291]="Долой захватчиков!",
    [8294]="Громи захватчиков-Среброкрылых!",[8295]="Громи захватчиков-Среброкрылых!",[8297]="Ресурсы Низины Арати",
    [8299]="Перекрыть линии поставок Аратора",[8301]="Путь праведника",[8302]="Рука праведника",[8303]="Анахронос",
    [8304]="Дражайшая Наталия",[8305]="Давно забытые воспоминания",[8307]="Блюдо из червей",
    [8308]="Потерянное письмо Бранна Бронзоборода",[8309]="Поиски рун",[8313]="Наделение знаниями",
    [8314]="Разгадка тайны",[8315]="Зов",[8317]="Помощь по кухне",[8318]="Тайные послания",
    [8319]="Зашифрованные Сумеречные тексты",[8320]="Геолорды из культа Сумеречного Молота",[8322]="Тухлые яйца",
    [8323]="Истинно верующие",[8324]="Не теряя веры",[8325]="Очищение острова Солнечного Скитальца",
    [8326]="Вынужденные меры",[8328]="Обучение мага",[8330]="Вещи Соланиана",[8331]="Аурель Золотой Лист",
    [8332]="Герцоги Совета",[8333]="Статусный медальон",[8334]="Агрессия",[8335]="Фелендрен Изгой",
    [8336]="Пригоршня осколков",[8338]="Оскверненный магический осколок",
    [8339]="Royalty of the Council <NYI> <TXT> UNUSED",[8341]="Лорды Совета",
    [8342]="Кольцо Власти служителя культа Сумеречного Молота",[8344]="Windows to the Source",
    [8345]="Святилище Дат'Ремара",[8346]="Неутолимая жажда",[8347]="Помощь курьерам",[8348]="Перстень герцогов",
    [8349]="Бор Буйная Грива",[8350]="Доставка посылки",[8351]="Разговор с Бором",[8360]="Танец за марципан",
    [8361]="Связь с Бездной",[8362]="Талисманы Бездны",[8363]="Перстни Бездны",[8364]="Скипетры Бездны",
    [8365]="Пиратские шляпы",[8367]="Великая честь",[8368]="Битва за ущелье Песни Войны",
    [8369]="Вторжение в Альтеракскую долину",[8371]="В едином порыве",[8373]="Сила сосен",
    [8374]="Завоевание Низины Арати",[8375]="Помни Альтеракскую долину!",[8376]="Оружие войны",[8377]="Оружие войны",
    [8378]="Оружие войны",[8379]="Оружие войны",[8380]="Оружие войны",[8381]="Оружие войны",[8382]="Оружие войны",
    [8383]="Помни Альтеракскую долину!",[8385]="В едином порыве",[8386]="Битва за ущелье Песни Войны",
    [8388]="Великая честь",[8389]="Битва за ущелье Песни Войны",[8390]="Завоевание Низины Арати",
    [8391]="Завоевание Низины Арати",[8392]="Завоевание Низины Арати",[8393]="Завоевание Низины Арати",
    [8394]="Завоевание Низины Арати",[8395]="Завоевание Низины Арати",[8396]="Завоевание Низины Арати",
    [8397]="Завоевание Низины Арати",[8398]="Завоевание Низины Арати",[8399]="Битва за ущелье Песни Войны",
    [8400]="Битва за ущелье Песни Войны",[8401]="Битва за ущелье Песни Войны",[8402]="Битва за ущелье Песни Войны",
    [8403]="Битва за ущелье Песни Войны",[8404]="Битва за ущелье Песни Войны",[8405]="Битва за ущелье Песни Войны",
    [8406]="Битва за ущелье Песни Войны",[8407]="Битва за ущелье Песни Войны",[8425]="Вудуистские перья",
    [8426]="Битва за ущелье Песни Войны",[8427]="Битва за ущелье Песни Войны",[8428]="Битва за ущелье Песни Войны",
    [8429]="Битва за ущелье Песни Войны",[8430]="Битва за ущелье Песни Войны",[8431]="Битва за ущелье Песни Войны",
    [8432]="Битва за ущелье Песни Войны",[8433]="Битва за ущелье Песни Войны",[8434]="Битва за ущелье Песни Войны",
    [8435]="Битва за ущелье Песни Войны",[8436]="Завоевание Низины Арати",[8437]="Завоевание Низины Арати",
    [8438]="Завоевание Низины Арати",[8439]="Завоевание Низины Арати",[8440]="Завоевание Низины Арати",
    [8441]="Завоевание Низины Арати",[8442]="Завоевание Низины Арати",[8447]="Пробуждение легенд",
    [8460]="Союзник Древобрюхов",[8461]="Северные фурболги Мертвого Леса",[8462]="Беседа с Нафиэном",
    [8463]="Нестабильные кристаллы маны",[8464]="Боевые действия в деревне Зимней Спячки",[8465]="Разговор с Сальфой",
    [8466]="Перья для Гразла",[8467]="Перья для Нафиэна",[8468]="Разыскивается: Таэлис Ненасытный",
    [8469]="Бусы для Сальфы",[8470]="Ритуальный тотем Мертвого Леса",[8471]="Ритуальный тотем Зимней Спячки",
    [8472]="Серьезная неполадка",[8473]="Печальное задание",[8474]="Подвеска Старого Белоствола",
    [8475]="Тропа Мертвых",[8476]="Угроза Амани",[8477]="Молот копьедела",[8479]="Зул'Марош",
    [8480]="Потерянное оружие",[8481]="Корень всех зол",[8482]="Обличающие документы",[8483]="Дворфийский шпион",
    [8484]="Знак мира",[8485]="Знак мира",[8486]="Магическая нестабильность",[8487]="Зараженная почва",
    [8488]="Неожиданный результат",[8489]="Невредимый преобразователь",[8490]="Усиление обороны",
    [8495]="Альянсу по-прежнему не хватает железных слитков!",[8496]="Запас бинтов",[8497]="Неприкосновенный запас",
    [8500]="Альянсу по-прежнему не хватает ториевых слитков!",[8501]="Цель: острожалы из улья Аши",
    [8506]="Альянсу по-прежнему не хватает лилового лотоса!",[8507]="Рутинное задание",
    [8518]="Альянсу по-прежнему не хватает льняных бинтов!",[8533]="Орде по-прежнему не хватает медных слитков!",
    [8534]="Донесение разведчика из Улья Зора",[8535]="Седой храмовник",[8536]="Земляной храмовник",
    [8537]="Багровый храмовник",[8538]="Четыре герцога",[8539]="Цель: сестры-убийцы из Улья Зора",
    [8540]="Сапоги для стражей",[8543]="Орде все еще нужны оловянные слитки!",
    [8546]="Орде все еще не хватает мифриловых слитков!",[8547]="Привет!",[8550]="Орде все еще не хватает мироцвета!",
    [8551]="Сундук капитана",[8552]="Кушак с монограммой",[8553]="Капитанская сабля",[8554]="Бой с Неголашем",
    [8555]="Создание драконов",[8556]="Перстень неумолимой силы",[8557]="Пелерина неумолимой силы",
    [8558]="Серп неумолимой силы",[8559]="Наголенники Завоевателя",[8560]="Набедренники Завоевателя",
    [8561]="Корона Завоевателя",[8564]="Обучение жреца",[8565]="Былые победы в Арати",[8566]="Былые победы в Арати",
    [8567]="Былые победы в ущелье Песни Войны",[8568]="Былые победы в ущелье Песни Войны",
    [8569]="Былые сражения в ущелье Песни Войны",[8570]="Былые сражения в ущелье Песни Войны",[8572]="Броня ветерана",
    [8573]="Броня защитника",[8574]="Стойкая броня",[8575]="Магическая книга Азурегоса",[8576]="Перевод книги",
    [8577]="Тушеный Лис, БЛД",[8578]="Гадальные очки? Без проблем!",[8583]="Орде все еще не хватает лилового лотоса!",
    [8584]="Никогда не расспрашивай меня о моем бизнесе!",[8585]="Остров Ужаса!",
    [8586]="Зажигательные отбивные Могиля из химерока",[8591]="Орде все еще не хватает плотной кожи!",
    [8592]="Тиара Оракула",[8593]="Брюки Оракула",[8594]="Оплечье Оракула",
    [8595]="Поборники правого дела из числа смертных",[8596]="Обмотки Оракула",
    [8597]="\"Драконий язык для чайников\"",[8598]="вЫкУП",[8601]="Орде все еще не хватает грубой кожи!",
    [8602]="Наплечье Зовущего бурю",[8605]="Орде все еще не хватает шерстяных бинтов!",[8619]="Предок Утренний Туман",
    [8620]="Единственный способ",[8621]="Прочные ботинки Зовущего бурю",[8622]="Хауберк Зовущего бурю",
    [8623]="Диадема Зовущего бурю",[8624]="Поножи Зовущего Бурю",[8625]="Наплечные пластины таинства",
    [8626]="Прочные ботинки бойца",[8627]="Кираса Мстителя",[8628]="Корона Мстителя",[8629]="Набедренники Мстителя",
    [8630]="Наплечье Мстителя",[8631]="Поножи Таинства",[8632]="Венец Таинства",[8633]="Одеяния Таинства",
    [8636]="Предок Скалогром",[8637]="Сапоги торговца смертью",[8638]="Жилет торговца смертью",
    [8639]="Шлем торговца смертью",[8640]="Поножи торговца смертью",[8654]="Предок Первокамень",
    [8655]="Наголенники Мстителя",[8656]="Хауберк Бойца",[8657]="Диадема бойца",[8658]="Поножи Бойца",
    [8659]="Наплечье Бойца",[8660]="Обмотки призывателя рока",[8661]="Одеяния призывателя рока",
    [8662]="Венец призывателя рока",[8663]="Брюки призывателя рока",[8664]="Оплечье призывателя рока",
    [8665]="Сапоги сотворения",[8666]="Жилет сотворения",[8667]="Шлем сотворения",[8668]="Брюки сотворения",
    [8686]="Предок Высокогор",[8688]="Предок Вестник Ветров",[8689]="Накидка Бесконечной мудрости",
    [8690]="Плащ надвигающейся бури",[8691]="Пелерина Погребенных тайн",[8692]="Плащ Бесконечной жизни",
    [8693]="Плащ сокрытых теней",[8694]="Накидка Неназванных имен",[8695]="Накидка Вечной справедливости",
    [8696]="Плащ Незримого пути",[8697]="Кольцо Бесконечной мудрости",[8698]="Кольцо надвигающейся бури",
    [8699]="Кольцо Погребенных тайн",[8700]="Кольцо Бесконечной жизни",[8701]="Кольцо сокрытых теней",
    [8702]="Кольцо Неназванных Имен",[8703]="Кольцо Вечной справедливости",[8704]="Перстень Незримого пути",
    [8705]="Чекан Беспредельной мудрости",[8706]="Молот надвигающейся бури",[8707]="Клинок Погребенных тайн",
    [8708]="Палица Бесконечной жизни",[8709]="Кинжал сокрытых теней",[8710]="Крис Неназванных имен",
    [8711]="Клинок Вечной справедливости",[8727]="Предок Тихий Шепот",[8728]="Хорошая новость и плохая новость",
    [8729]="Гнев Нептулона",[8730]="Порча Нефария",[8731]="Рутинное задание",[8732]="Бумаги о полевых обязанностях",
    [8733]="Эраникус, Тиран Сна",[8734]="Тиранда и Ремул",[8735]="Порча Кошмара",[8736]="Явление Кошмара",
    [8737]="Лазурный храмовник",[8738]="Донесение разведчика из Улья Регал",[8739]="Донесение разведчика из Улья Аши",
    [8740]="Сумеречные мародеры",[8741]="Возвращение победителя",[8742]="Армия Калимдора",
    [8744]="Тщательно завернутый подарок",[8746]="Метцен-северный олень",[8747]="Путь защитника",
    [8748]="Путь защитника",[8749]="Путь защитника",[8750]="Путь защитника",[8751]="Защитник Калимдора",
    [8752]="Путь победителя",[8753]="Путь победителя",[8754]="Путь победителя",[8755]="Путь победителя",
    [8756]="Победитель киражей",[8757]="Путь заклинателя",[8758]="Путь заклинателя",[8759]="Путь заклинателя",
    [8760]="Путь заклинателя",[8763]="Герой дня",[8764]="Изменение пути – уже не защитник",
    [8765]="Изменение пути – уже не заклинатель",[8769]="Тикающий подарок",[8770]="Цель: защитники из Улья Аши",
    [8771]="Цель: песчаные ловцы из улья Аши",[8772]="Цель: стражи дорог из Улья Зора",
    [8773]="Цель: разрушители из Улья Зора",[8774]="Цель: стерегущие из Улья Регал",
    [8775]="Цель: огнеполохи из улья Регал",[8776]="Цель: поработители из улья Регал",
    [8777]="Цель: землерои из Улья Регал",[8778]="Взрывчатка для дружины Стальгорна",[8779]="Материалы для гадания",
    [8780]="Комплекты брони",[8781]="Нехватка оружия",[8782]="Поставки формы",[8783]="Необычные материалы",
    [8784]="Секреты Кираи",[8785]="Амулеты для легиона Оргриммара",[8786]="Нехватка оружия",
    [8788]="Слегка помятый подарок",[8789]="Киражское императорское оружие",[8790]="Киражские императорские регалии",
    [8797]="Альянсу нужна твоя помощь!",[8799]="Герой дня",[8800]="Броня Кенария",[8801]="Наследие К'Туна",
    [8803]="Подарок в разноцветной упаковке",[8804]="Неприкосновенный запас",[8805]="Сапоги для стражей",
    [8806]="Шлифовальные камни",[8807]="Материалы для гадания",[8808]="Поставки формы",[8809]="Необычные материалы",
    [8828]="Подарки Дедушки Зимы",[8855]="Тридцать жетонов в обмен на припасы",[8856]="Неприкосновенный запас",
    [8857]="Тайны колосса – Аши",[8858]="Тайны колосса – Регал",[8883]="Валадар Звездная Песня",
    [8884]="Рыбьи головы, рыбьи головы...",[8885]="Кольцо Мррргла",[8886]="На помощь! Пираты!",
    [8887]="Утраченные карты капитана Келисендры",[8888]="Ученица магистра",[8889]="Отключить замок",
    [8890]="Весточка из замка",[8891]="Неоконченное исследование",[8892]="Проблемы на причале Солнечного Паруса",
    [8893]="Супер Яйц-О-Матик",[8894]="Зачистка территории",[8895]="Послание в Северное святилище",
    [8904]="Опасная любовь",[8905]="Серьезное предложение",[8906]="Серьезное предложение",
    [8907]="Серьезное предложение",[8908]="Серьезное предложение",[8909]="Серьезное предложение",
    [8910]="Серьезное предложение",[8911]="Серьезное предложение",[8912]="Серьезное предложение",
    [8913]="Серьезное предложение",[8914]="Серьезное предложение",[8915]="Серьезное предложение",
    [8916]="Серьезное предложение",[8917]="Серьезное предложение",[8918]="Серьезное предложение",
    [8919]="Серьезное предложение",[8920]="Серьезное предложение",[8921]="Эктоплазматический дистиллятор",
    [8922]="Сверхъестественное устройство",[8923]="Сверхъестественное устройство",[8924]="В поисках эктоплазмы",
    [8925]="Портативный источник энергии",[8926]="Справедливое вознаграждение",[8927]="Справедливое вознаграждение",
    [8928]="Сомнительный торговец",[8929]="В поисках Антиона",[8930]="В поисках Антиона",
    [8931]="Справедливое вознаграждение",[8932]="Справедливое вознаграждение",[8933]="Справедливое вознаграждение",
    [8934]="Справедливое вознаграждение",[8935]="Справедливое вознаграждение",[8936]="Справедливое вознаграждение",
    [8937]="Справедливое вознаграждение",[8938]="Справедливое вознаграждение",[8939]="Справедливое вознаграждение",
    [8940]="Справедливое вознаграждение",[8941]="Справедливое вознаграждение",[8942]="Справедливое вознаграждение",
    [8943]="Справедливое вознаграждение",[8944]="Справедливое вознаграждение",[8945]="Просьба мертвеца",
    [8946]="Доказательство жизни",[8947]="Странная просьба Антиона",[8948]="Старый приятель Антиона",
    [8949]="Кровная месть Фарлина",[8950]="Чары подстрекателя",[8951]="Прощальные слова Антиона",
    [8952]="Прощальные слова Антиона",[8953]="Прощальные слова Антиона",[8954]="Прощальные слова Антиона",
    [8955]="Прощальные слова Антиона",[8956]="Прощальные слова Антиона",[8957]="Прощальные слова Антиона",
    [8958]="Прощальные слова Антиона",[8959]="Прощальные слова Антиона",[8960]="Злосчастная доля Бодли",
    [8961]="Три властелина огня",[8962]="Важная составляющая заклинания",[8963]="Важная составляющая заклинания",
    [8964]="Важная составляющая заклинания",[8965]="Важная составляющая заклинания",
    [8966]="Левая часть амулета Лорда Вальтхалака",[8967]="Левая часть амулета Лорда Вальтхалака",
    [8968]="Левая часть амулета Лорда Вальтхалака",[8969]="Левая часть амулета Лорда Вальтхалака",
    [8970]="Я вижу в твоем будущем остров Алькац...",[8977]="Возвращение к Делиане",[8984]="Источник обнаружен",
    [8985]="Еще одна важная составляющая заклинания",[8986]="Еще одна важная составляющая заклинания",
    [8987]="Еще одна важная составляющая заклинания",[8988]="Еще одна важная составляющая заклинания",
    [8989]="Правая часть амулета Лорда Вальтхалака",[8990]="Правая часть амулета Лорда Вальтхалака",
    [8991]="Правая часть амулета Лорда Вальтхалака",[8993]="Подношение даров",[8994]="Последние приготовления",
    [8995]="Mea Culpa, Лорд Вальтхалак",[8996]="Возвращение к Бодли",[8997]="Круг замкнулся",[8998]="Круг замкнулся",
    [8999]="Сладкое – на закуску",[9000]="Сладкое – на закуску",[9001]="Сладкое – на закуску",
    [9002]="Сладкое – на закуску",[9003]="Сладкое – на закуску",[9004]="Сладкое – на закуску",
    [9005]="Сладкое – на закуску",[9006]="Сладкое – на закуску",[9007]="Сладкое – на закуску",
    [9008]="Сладкое – на закуску",[9009]="Сладкое – на закуску",[9010]="Сладкое – на закуску",
    [9011]="Сладкое – на закуску",[9012]="Сладкое – на закуску",[9013]="Сладкое – на закуску",
    [9014]="Сладкое – на закуску",[9015]="Вызов",[9016]="Прощальные слова Антиона",[9017]="Прощальные слова Антиона",
    [9018]="Прощальные слова Антиона",[9019]="Прощальные слова Антиона",[9020]="Прощальные слова Антиона",
    [9021]="Прощальные слова Антиона",[9022]="Прощальные слова Антиона",[9028]="Источник обнаружен",
    [9029]="Бурлящий котел",[9030]="Прощальные слова Антиона",[9032]="Злосчастная доля Бодли",
    [9033]="Отголоски войны",[9034]="Кираса неустрашимости",[9035]="Засада на дороге",
    [9036]="Ножные латы неустрашимости",[9037]="Полный шлем неустрашимости",[9038]="Наплечье неустрашимости",
    [9039]="Башмаки неустрашимости",[9040]="Рукавицы неустрашимости",[9041]="Воинский пояс неустрашимости",
    [9042]="Наручи неустрашимости",[9043]="Мундир Искупления",[9044]="Набедренники Искупления",
    [9045]="Головной убор Искупления",[9046]="Наплеч Искупления",[9047]="Сапоги Искупления",
    [9048]="Боевые рукавицы Искупления",[9049]="Ремень Искупления",[9053]="Лучший ингредиент",
    [9054]="Мундир расхитителя гробниц",[9055]="Набедренники расхитителя гробниц",
    [9056]="Головной убор расхитителя гробниц",[9057]="Наплеч расхитителя гробниц",
    [9058]="Сапоги расхитителя гробниц",[9059]="Боевые рукавицы Расхитителя гробниц",
    [9060]="Ремень расхитителя гробниц",[9061]="Накулачники расхитителя гробниц",[9063]="Землепроходец Торва",
    [9064]="Взять вину на себя",[9065]="Задание Чоу (123)аа",[9066]="Суровый урок",[9067]="Бесконечный праздник",
    [9068]="Мундир Землекрушителя",[9069]="Набедренники Землекрушителя",[9070]="Головной убор Землекрушителя",
    [9071]="Наплеч Землекрушителя",[9072]="Сапоги Землекрушителя",[9073]="Боевые рукавицы Землекрушителя",
    [9074]="Ремень Землекрушителя",[9075]="Накулачники Землекрушителя",[9076]="Главарь Презренных",
    [9077]="Кираса костяной косы",[9078]="Ножные латы костяной косы",[9079]="Полный шлем костяной косы",
    [9080]="Наплечье костяной косы",[9081]="Башмаки костяной косы",[9082]="Рукавицы костяной косы",
    [9083]="Воинский пояс костяной косы",[9085]="Тени Рока",[9086]="Мундир сновидца",[9087]="Набедренники сновидца",
    [9088]="Головной убор сновидца",[9089]="Наплеч сновидца",[9090]="Сапоги сновидца",
    [9091]="Боевые рукавицы сновидца",[9092]="Ремень сновидца",[9093]="Накулачники сновидца",
    [9094]="Перчатки Серебряного Рассвета",[9095]="Одеяние ледяного огня",[9096]="Поножи ледяного огня",
    [9097]="Венец ледяного огня",[9098]="Наплечные пластины ледяного огня",[9099]="Сандалии ледяного огня",
    [9100]="Перчатки ледяного огня",[9101]="Пояс ледяного огня",[9102]="Наручники ледяного огня",
    [9103]="Одеяние Проклятого Сердца",[9104]="Поножи Проклятого Сердца",[9105]="Венец Проклятого Сердца",
    [9106]="Наплечные пластины Проклятого Сердца",[9107]="Сандалии Проклятого Сердца",
    [9108]="Перчатки Проклятого Сердца",[9109]="Пояс Проклятого Сердца",[9110]="Наручники Проклятого Сердца",
    [9111]="Одеяние веры",[9112]="Поножи веры",[9113]="Венец веры",[9114]="Наплечные пластины веры",
    [9115]="Сандалии веры",[9116]="Перчатки веры",[9117]="Пояс веры",[9118]="Наручники веры",
    [9119]="Авария в Западном святилище",[9120]="Падение Кел'Тузада",[9121]="Цитадель ужаса – Наксрамас",
    [9122]="Цитадель ужаса – Наксрамас",[9123]="Цитадель ужаса – Наксрамас",
    [9124]="Доспехи расхитителя гробниц на дороге не валяются...",[9125]="Конечности и панцири некрорахнидов",
    [9126]="Копи костяной косы",[9127]="Обломки костей",[9128]="Уравнение стихий",[9129]="Средоточие стихий",
    [9130]="Товары из Луносвета",[9131]="Броня неустрашимости",[9132]="Лом черного железа",[9133]="Полет в Луносвет",
    [9134]="Повелительница небес Полудымка",[9135]="Возвращение к интенданту Лимель",[9136]="Дикая флора",
    [9137]="Дикие ростки",[9138]="Деревня Солнечной Короны",[9139]="Деревня Золотистой Дымки",
    [9140]="Деревня Ветрокрылых",[9141]="Не все так просто",[9142]="Задание мастера",[9143]="Неприятности в Зеб'Соре",
    [9144]="Пропавший в Призрачных землях",[9145]="Спасти следопыта Валанну",[9146]="Донесение капитану Гелиосу",
    [9147]="Умирающий курьер",[9148]="Письмо в Транкивиллион",[9149]="Чумной берег",[9150]="Спасение прошлого",
    [9151]="Святилище Солнца",[9154]="Часовня Последней Надежды",[9155]="По Тропе Мертвых",
    [9156]="Разыскиваются: Гнилоступ и Лузран",[9157]="Забытые обряды",[9158]="Разносчики заразы",
    [9159]="Обуздание заразы",[9160]="Обследование Ан'дарота",[9161]="Тень предателя",[9162]="Отблески былого",
    [9163]="Вылазка на оккупированную территорию",[9164]="Пленники Смертхольма",[9165]="Подорожная",
    [9166]="Донесение в Ан'телас",[9167]="Гибель предателя",[9168]="Сердце Смертхольма",[9169]="Ан'овин: отключение",
    [9170]="Приспешники Дар'Хана",[9171]="Хрустящий деликатес",[9172]="Доклад магистру Кендрису",
    [9173]="Захват шпилей Ветрокрылых",[9174]="Победа над Аквантионом",[9175]="Ожерелье Госпожи",
    [9176]="Зиккураты-близнецы",[9177]="Путь в Подгород",[9178]="Задание мастера – массивное грузило",
    [9179]="Задание мастера: имперский латный нагрудник",[9180]="Путь в Подгород",
    [9181]="Задание мастера: вулканический молот",[9182]="Задание мастера: огромный ториевый боевой топор",
    [9183]="Задание мастера: светозарный венец",[9184]="Задание мастера: гибельная кожаная головная повязка",
    [9185]="Задание мастера: накладки из грубой кожи",[9186]="Задание мастера: гибельный кожаный пояс",
    [9187]="Задание мастера: рунические кожаные штаны",[9188]="Задание мастера: штаны из яркой ткани",
    [9189]="Посылка в Гробницу",[9190]="Задание мастера: сапоги из рунической ткани",
    [9191]="Задание мастера: сумка из рунической ткани",[9192]="Беда в Беспросветных рудниках",
    [9193]="Обследование катакомб Амани",[9194]="Задание мастера: одеяние из рунической ткани",
    [9195]="Задание мастера: гоблинская мина",[9196]="Задание мастера: ториевая граната",
    [9197]="Задание мастера: боевой цыпленок гномов",[9198]="Задание мастера: ториевая труба",[9199]="Джуджу троллей",
    [9200]="Задание мастера – сильнейшее зелье маны",[9201]="Задание мастера: сильное зелье защиты от тайной магии",
    [9202]="Задание мастера: огромный флакон с лечебным зельем",[9203]="Задание мастера: зелье оцепенения",
    [9204]="Задание мастера: каменный угорь",[9205]="Задание мастера: пластинчатая бронерыба",
    [9206]="Задание мастера: молниевый угорь",[9207]="Образцы руды из Беспросветных рудников",
    [9208]="Защита Джунглей – Магический камень защиты",[9209]="Защита Джунглей – Магический камень стремительности",
    [9210]="Защита Джунглей – Магический камень сосредоточения",[9211]="Ледяная защита",[9212]="Бегство из Катакомб",
    [9213]="Теневая защита",[9214]="Оружие Призрачной Сосны",[9215]="Награда за голову Келгаша!",
    [9216]="Гниющие сердца",[9217]="Больше гниющих сердец",[9218]="Позвоночный порошок",
    [9219]="Больше позвоночного порошка",[9220]="Война со Смертхольмом",
    [9221]="Превосходное боевое снаряжениее – Друг Рассвета",[9222]="Легендарное боевое снаряжение – Друг Рассвета",
    [9223]="Превосходное боевое снаряжение – Уважаемый Рассветом",
    [9224]="Легендарное снаряжение – Уважаемый Рассветом",[9225]="Легендарное боевое снаряжение – Чтимый Рассветом",
    [9226]="Превосходное боевое снаряжениее – Чтимый Рассветом",
    [9227]="Превосходное боевое снаряжениее – Восторг Рассвета",
    [9228]="Легендарное боевое снаряжение – Восторг Рассвета",[9229]="Кольцо Судьбы Рамаладни",
    [9230]="Ледяная хватка Рамаладни",[9232]="Не разгуляешься...",[9233]="Руководство Омариона",
    [9234]="Рукавицы ледяной погибели",[9235]="Наручи ледяной погибели",[9236]="Кираса ледяной погибели",
    [9237]="Ледовый плащ",[9238]="Ледовые накулачники",[9239]="Ледовые перчатки",[9240]="Ледовый жилет",
    [9241]="Снежные наручи",[9242]="Снежные перчатки",[9243]="Снежный мундир",[9244]="Наручи из ледяной чешуи",
    [9245]="Рукавицы из ледяной чешуи",[9247]="Зов Хранителя",[9251]="Атиеш, оскверненный посох",
    [9252]="Оборона деревни Легкий Ветерок",[9253]="Хранитель рун Дериан",[9254]="Упрямая ученица",
    [9255]="Исследовательские записи",[9257]="Атиеш, большой посох Стража",[9258]="Выжженная роща",
    [9265]="Что делает Плеть в Подгороде?",[9266]="Восстановление добрых отношений",[9267]="Исцеление старых ран",
    [9271]="Атиеш, большой посох Стража",[9272]="Костюм пирата",[9274]="Духи утопших",[9275]="Острое блюдо",
    [9276]="Нападение на Зеб'Телу",[9277]="Нападение на Зеб'Нову",[9278]="Привет!",[9279]="Тебе удалось выжить!",
    [9280]="Исцеляющие кристаллы",[9281]="Расчистка пути",[9282]="Анклав Странников",[9283]="Помощь выжившим",
    [9284]="Тест группы Алдора",[9285]="Тест группы Консорциума",[9292]="Треснувший некротический кристалл",
    [9293]="То, что должно быть сделано...",[9302]="Послание с фронта",[9304]="Документ с фронта",
    [9305]="Запасные части",[9310]="Тусклый некротический кристалл",[9311]="Шпион эльфов крови",[9312]="Излучатель",
    [9313]="На Лазурную заставу",[9314]="Вести с Лазурной заставы",[9315]="Анок'сутен",[9317]="Освященное точило",
    [9319]="Свет в темных местах",[9320]="Гигантский флакон с зельем маны",[9326]="Похищение пламени Подгорода",
    [9327]="Отрекшиеся",[9328]="Герой син'дорай",[9332]="Похищение пламени Дарнаса",
    [9333]="Перчатки Серебряного Рассвета",[9334]="Благословленное волшебное масло",[9335]="Освященное точило",
    [9336]="Гигантский флакон с лечебным зельем",[9337]="Гигантский флакон с зельем маны",[9339]="Награда вора",
    [9341]="Гербовая накидка Серебряного Рассвета",[9343]="Гербовая накидка Серебряного Рассвета",
    [9344]="Поспешный отъезд",[9345]="Изготовление мази",[9346]="Зловепрь – птица гордая",
    [9349]="Сбор яиц опустошителей",[9351]="Дикие демоны Бездны",[9352]="Вторжение из Дарнаса",
    [9355]="Работа для сообразительных",[9356]="Летать как птица",[9357]="Задание Аэльдона Озаренного Солнцем",
    [9358]="Следопыт Сарейн",[9359]="Обитель Странников",[9360]="Вторжение племени Амани",
    [9362]="Полководец Креллиан",[9365]="Награда вора",[9368]="Праздник Огня",[9369]="Исцеляющие кристаллы",
    [9370]="Остановить очищение",[9371]="Ботаник Таэрикс",[9372]="Распространение демонической скверны",
    [9373]="Потерянное послание",[9374]="Записи Арелиона",[9375]="Дорога к Соколиному дозору",
    [9376]="Скарб пилигрима",[9380]="В погоне за большим",[9381]="Стрелы, бьющие без промаха",
    [9382]="Жестокий рок копытня",[9383]="Честолюбивый план",[9386]="Свет в темных местах",
    [9389]="Мерцающие огни Восточных королевств",[9390]="Найти Седаи",[9393]="Обучение охотника",
    [9394]="Куда подевался Виллитен?",[9395]="Вилла Салтерила",[9396]="Магия араккоа",[9397]="Пух и перья",
    [9398]="Смертельно опасные хищники",[9399]="Безжалостные десятники",[9400]="Убийца",[9404]="Живая ветка",
    [9405]="Поручение Вождя",[9406]="Маг'хары",[9407]="Через Темный портал",[9408]="Забытые герои",
    [9409]="Срочная доставка",[9410]="Хранитель душ",[9415]="Маршал Синяя Синестен",[9416]="Генерал Кирика",
    [9417]="Угроза Араккоа",[9418]="Сфера Авруу",[9419]="Истощение пустыни",[9421]="Обучение шамана",
    [9422]="Истощение пустыни",[9423]="Возвращение к Обадию",[9424]="Месть Макуру",
    [9425]="Возвращение в Мельницу Таррен",[9426]="Пруды Аггонара",[9427]="Очищение вод",
    [9428]="На заставу Расщепленного Дерева",[9429]="Путешествие в Темнолесье",[9430]="Реликвии Ша'наара",
    [9431]="Разный подход",[9432]="Дорога в Астранаар",[9433]="Проба из Лунного колодца",[9434]="Испытание тоника",
    [9435]="Пропавшие кристаллы",[9436]="Изучение Кровавого Скальпа",[9437]="Сумерки \"Гонца Рассвета\"",
    [9438]="Донесение Траллу",[9439]="Потерянный багаж",[9440]="Маленькие кусочки",[9441]="Посол к маг'харам",
    [9442]="Изнуряющая слабость",[9443]="Так называемый знак Светоносного",[9444]="Осквернение гробницы Утера",
    [9446]="Гробница Светоносного",[9447]="Применение целебной мази",[9451]="Зов земли",
    [9452]="Деликатесный красный луциан",[9453]="Поиски Актеона",[9454]="Великая охота на лунных оленей",
    [9455]="Странные находки",[9456]="Истребление ночных ловцов, остров 2...",[9462]="Зов Огня",[9465]="Зов Огня",
    [9468]="Зов Огня",[9469]="Встреча с Перобородом",[9470]="Жест доброй воли",[9471]="Охота на хищников",
    [9472]="Любовница Арелиона",[9473]="Другое решение",[9474]="Знак Светоносного",[9475]="Похищенные яйца",
    [9476]="В поисках Пероборода",[9489]="Поднять боевой дух",[9491]="Не откажусь",[9492]="Новый поворот событий",
    [9493]="Элита Орды Скверны",[9494]="Угли Скверны",[9495]="Воля Вождя",[9496]="Элита Орды Скверны",
    [9498]="Соколиный дозор",[9504]="Зов Воды",[9505]="Пророчество Велена",[9509]="Зов Воды",
    [9510]="Шкура щетинистого копытня",[9511]="Боевые планы Каргата",[9512]="Крабовый супчик поваренка",
    [9513]="Возвращение руин",[9514]="Покрытая рунами табличка",[9515]="Полководец Шрисс'тиз",
    [9516]="Уничтожить Легион!",[9517]="Напрасные усилия",[9518]="Пособники разрушения",[9519]="Потерянная чаша",
    [9520]="Демонические планы",[9521]="Донесение с северного фронта",[9522]="Больше никогда!",
    [9523]="Хрупкие предметы. Не кантовать!",[9524]="Узник цитадели",[9525]="Узник цитадели",
    [9526]="Возрождение Холма Демонического Огня",[9527]="Все, что осталось",[9529]="Камень",[9530]="Созревший план",
    [9532]="Найти Келтуса Темного Листа",[9533]="Рука помощи",[9534]="Уничтожить Легион!",[9535]="Демонические планы",
    [9536]="Больше никогда!",[9537]="Не ведая пощады",[9538]="Изучение языка",[9539]="Тотем Ку",[9540]="Тотем Тикти",
    [9541]="Тотем Йора",[9542]="Тотем Варк",[9543]="Искупление",[9544]="Пророчество Акиды",[9547]="Зов воздуха",
    [9548]="Украденное снаряжение",[9549]="Артефакты племени Черного Ила",[9555]="Зов огня",[9556]="Вода для мага",
    [9557]="Расшифровка книги",[9558]="Длиннобородые",[9559]="Логово племени Тихвой",[9560]="Звери Судного дня!",
    [9561]="Записи Нолкаи",[9562]="Мурлоки... За что нам эта напасть?",[9563]="Доверие Миррена",
    [9564]="Клок шерсти Гурфа",[9565]="Поиски в логове племени Тихвой",[9566]="Кровавые кристаллы",
    [9567]="Лицо врага",[9568]="Лучшая защита",[9569]="Противостояние",[9570]="Куркен-жмуркен",[9571]="Шкура Куркена",
    [9572]="Ослабить оборону валов",[9573]="Вождь Умуру",[9574]="Отравленные скверной",
    [9575]="Ослабить оборону валов",[9576]="Ожерелье Жестокого Плавника",[9578]="В поисках Галена",
    [9579]="Судьба Галена",[9580]="Вскормленные медвежатиной",[9582]="Силой единой",[9584]="Второй образец",
    [9586]="Помощь Таваре",[9587]="Предвестье беды",[9588]="Предвестье беды",[9589]="Кровь есть жизнь",
    [9593]="Приручение зверя",[9601]="В Бастион",[9602]="Избавь их от лукавого...",
    [9603]="Лежанки, лекарства и прочая ерунда",[9604]="На крыльях гиппогрифа",
    [9605]="Укротитель гиппогрифов Стефанос",[9606]="Возвращение к Тоферу Лоаалу",[9607]="В сердце ярости",
    [9608]="В сердце ярости",[9609]="Помощь дозорному Биггсу",[9610]="Озеро Слез",[9612]="Большое спасибо!",
    [9619]="Руна призыва",[9620]="Пропавшие картографы",[9621]="Посол к Орде",[9622]="Предупреди свой народ",
    [9623]="Время пришло",[9624]="Любимое блюдо",[9625]="Элекки – это серьезно",[9626]="Встреча с вождем",
    [9627]="Верность Орде",[9628]="Цена знания – жизнь",[9629]="Поймать и отпустить",[9630]="Дневник Медива",
    [9631]="Взаимовыручка",[9632]="Новые союзники",[9633]="Дорога к Аубердину",
    [9636]="Удаленный конденсатор выхлопов!",[9637]="Требование Калинны",[9638]="В хороших руках",[9639]="Камсис",
    [9640]="Тень Арана",[9641]="Осколки облученного кристалла",[9642]="И снова облученные кристаллы",
    [9643]="Удушающая лоза",[9644]="Ночная Погибель",[9645]="Терраса Мастера",[9646]="РАЗЫСКИВАЕТСЯ: Коготь Смерти",
    [9647]="Ловля бражников",[9648]="Грибная похлебочка Матпарма",[9649]="Слеза Изеры",[9663]="Дуга Кессела",
    [9664]="Новые форпосты",[9665]="Укрепим оборону",[9666]="Демонстрация силы",[9667]="Спасение принцессы Тихвой",
    [9668]="Доклад экзарху Адметиусу",[9669]="Пропавшая экспедиция",[9670]="Они живы! Может быть...",
    [9671]="Срочная доставка",[9673]="Дрессировка",[9678]="Первое испытание",[9681]="Источник силы",
    [9682]="Отчаявшиеся",[9686]="Второе испытание",[9687]="Святотатство",[9688]="Дорога в Сон",[9692]="Путь адепта",
    [9693]="Что для тебя Аргус?..",[9694]="Кровавая застава",[9696]="Переводы...",[9697]="Наблюдательница Лиса'о",
    [9698]="Аудиенция у Пророка",[9699]="Правда или вымысел",[9700]="Магия против Тьмы",
    [9701]="Наблюдение за спорлингами",[9702]="Вопросы питания",[9703]="Криогенный блок",
    [9704]="Смерть от рук Презренных",[9705]="Возвращение посылки",[9707]="Ковка оружия",[9708]="Знакомые грибы",
    [9710]="Закаленный кровью протазан",[9712]="Талассийский боевой конь",[9714]="Принеси мне еще одну клумбу!",
    [9715]="Принеси мне клумбу!",[9716]="Неприятности на озере Тенетопь",[9717]="Удачный ход",
    [9718]="С высоты птичьего полета",[9719]="Охота на Охотницу",[9723]="Жест преданности",
    [9725]="Доказательство лояльности",[9726]="Теперь, когда мы друзья...",[9727]="Раз уж мы по-прежнему друзья...",
    [9728]="Теплый прием",[9729]="Фхвур крушить!",[9730]="Предводитель Темного Гребня",[9731]="Схема стоков",
    [9732]="Назад в болото",[9733]="Предупреждение Кругу Кенария",[9737]="Истинные владыки Света",
    [9738]="Пропавшие без вести",[9739]="Проблемы спорлингов",[9740]="Солнечные Ворота",[9741]="Твари из Бездны",
    [9742]="Новые мешочки со спорами",[9743]="Природные враги",[9744]="Еще усиков!",[9746]="Границы возможного",
    [9747]="Племя Тенетопи",[9748]="Не пей эту воду!",[9749]="Они живы! Может быть…",[9750]="UNUSED Urgent Delivery",
    [9751]="Наследие Проклятой Крови",[9752]="Спасение с озера Тенетопь",[9753]="То, что мы знаем...",
    [9757]="Охотница Келла Тетива Ночи",[9758]="Возвращение к чародею Вандрилу",[9759]="Отречемся от старого мира",
    [9760]="Привал Защитника",[9761]="Расчистка пути",[9762]="Неписаное пророчество",[9763]="Убежище врага",
    [9764]="Приказы Леди Вайш",[9765]="Готовится к войне",[9766]="Оружие Кривого Клыка",
    [9767]="Врага нужно знать в лицо",[9769]="Мода непредсказуема!",[9770]="Опасные болотные клыки",
    [9771]="Поиски разведчика Джиобы",[9772]="Донесение разведчика Джиобы",[9773]="Довольно грибов!",
    [9774]="Толстая чешуя гидры",[9775]="Донесение темному охотнику Денжаю",[9776]="Прибежище Оребор",
    [9777]="Споры гриба-блескуна",[9778]="Страж Хамут",[9779]="Перехват сообщения",
    [9780]="Филе угрей из озера Тенетопь",[9781]="Слишком много ртов!",[9782]="Мертвая трясина",
    [9783]="Неестественная засуха",[9784]="Определение растений",[9785]="Благословение Древ",[9786]="Руины Боха'му",
    [9787]="Идолы Дикотопи",[9788]="Темное, сырое место",[9789]="Охота на копытней",[9790]="Прозрачные крылья",
    [9791]="Опасные болотные клыки",[9792]="Послание в Телаар",[9793]="Судьба Туурема",
    [9794]="Не время для любопытства",[9795]="Угроза со стороны огров",[9796]="Новости из Зангартопи",
    [9797]="Подкрепление для Гарадара",[9798]="Планы эльфов крови",[9799]="Сбор трав",[9800]="Редкий деликатес",
    [9801]="Сбор реагентов",[9802]="Растения Зангартопи",[9803]="Посланец в Дикотопь",
    [9804]="Беспокойные духи озера Небесной Песни",[9805]="Благословение Возжигателя",[9806]="Прорастающие споры",
    [9807]="Новые прорастающие споры",[9808]="Грибы-огнешляпки",[9809]="Нужно больше грибов!",
    [9810]="Оскверненный дух",[9811]="Друг син'дорай",[9812]="Посол к Орде",[9813]="Встреча с вождем",
    [9814]="Грибы-пороховики, слышь?",[9815]="Грязные делишки",[9816]="Видали вы такое?",
    [9817]="Глава клана Кровавой Чешуи",[9818]="Из глубин",[9819]="Истерзанные духи земли",
    [9820]="РАЗЫСКИВАЕТСЯ: Главарь Грог'ак",[9821]="Попробовать зло на зуб",[9822]="Угроза нападения",
    [9823]="Мы и они",[9824]="Колебания тайной магии",[9825]="Неустанный труд",[9826]="Вести из Даларана",
    [9827]="Высохшая базидия",[9828]="Высохшая базидия",[9829]="Кадгар",[9830]="Яд паразита",[9831]="Вход в Каражан",
    [9832]="Второй и третий фрагменты",[9833]="Линии связи",[9834]="Природная броня",
    [9835]="Вторжение клана Анго'рош",[9836]="Разрешение учителя",[9837]="Возвращение к Кадгару",
    [9838]="Аметистовое Око",[9839]="Властитель Кровавый Кулак",[9840]="Оценка ситуации",
    [9841]="Поделом гнусным тварям!",[9842]="Острейшие резцы",[9843]="Записи Кинны",[9844]="Присутствие демонов",
    [9845]="Не распугивайте рыбу!",[9846]="Духи Дикотопи",[9847]="Дух-союзник?",[9848]="Тайны Остротопи",
    [9849]="Сорвать личину",[9850]="Охота на копытней",[9851]="Охота на копытней",[9852]="Опасный спорт",
    [9853]="Гурок Узурпатор",[9854]="Охота на ветрухов",[9855]="Охота на ветрухов",[9856]="Охота на ветрухов",
    [9857]="Охота на талбуков",[9858]="Охота на талбуков",[9859]="Охота на талбуков",[9860]="Новое направление",
    [9861]="Вой-Ветер",[9862]="Разлагатели Темной Крови",[9863]="Вражеские святыни",[9864]="Пропавший отряд",
    [9865]="Да, были воины в наше время...",[9866]="Он будет странствовать по земле...",[9867]="Главари Темной Крови",
    [9868]="Тотем Кардаша",[9869]="Трон стихий",[9870]="Трон стихий",[9871]="Захватчики из племени Темной Крови",
    [9872]="Захватчики из племени Темной Крови",[9873]="Ортор, мой старый друг...",[9874]="Остановить заразу",
    [9875]="Неизвестный науке вид",[9876]="Провалившийся рейд",[9877]="Приводящее в сознание зелье",
    [9878]="Устранение проблемы",[9879]="Тотем Кардаша",[9882]="Украсть у вора",[9883]="Снова осколки кристалла",
    [9884]="Выгодное сотрудничество",[9885]="Выгодное сотрудничество",[9886]="Выгодное сотрудничество",
    [9887]="Выгодное сотрудничество",[9888]="Слабосильный владыка",[9889]="Толстяка не убивать",[9890]="Готово!",
    [9891]="Потому что Килрат – трус",[9892]="Поиски обсидиановых боевых ожерелий",
    [9893]="Обсидиановое боевое ожерелье",[9894]="Защита наблюдателей",[9895]="Гибнущее равновесие",
    [9896]="Проклятие черной бракониды",[9897]="Я спасена!",[9898]="Уважение к ближнему",[9899]="Несделанное дело",
    [9900]="Гава'кси",[9901]="Неоконченное дело",[9902]="Ужас озера Болотных Огоньков",[9903]="Самый здоровенный",
    [9904]="Охота на Жутеклешня",[9905]="Месть Макту",[9906]="Клинок вместо слов",[9907]="Дерзкий набег",
    [9910]="Страх и уважение",[9911]="Владыка болот",[9912]="Кенарийская экспедиция",[9913]="Консорциум ждет вас",
    [9914]="Кость на вес золота",[9915]="Кость на вес воздуха",[9916]="Припасы клана Кровавой Глазницы",
    [9917]="Не верь глазам своим",[9918]="Только не в мою смену!",[9919]="Спореггар",[9920]="Мо'мор Разрушитель",
    [9921]="Руины Пылающего Клинка",[9922]="Расселины Награнда",[9923]="На помощь!",[9924]="Корки снова пропал!",
    [9925]="Вопросы безопасности",[9926]="FLAG Совет Теней/Цепочка заданий Боевой Молот",
    [9927]="Безжалостное коварство",[9928]="Военная хитрость",[9929]="Пропавший торговец",[9930]="Пропавший торговец",
    [9931]="Взаимная вежливость",[9932]="Вещественное доказательство",[9933]="Послание в Телаар",
    [9934]="Послание в Гарадар",[9935]="Разыскивается: Гизельда Колдунья",[9936]="Разыскивается: Гизельда Колдунья",
    [9937]="Разыскивается: Дарн Ненасытный",[9938]="Разыскивается: Дарн Ненасытный",
    [9939]="Разыскивается: Зорбо Советчик",[9940]="Разыскивается: Зорбо Советчик",[9941]="Выслеживание преступников",
    [9942]="Выслеживание преступников",[9943]="Обратно к Тандеру",[9944]="Пропавший маг'харский караван",
    [9945]="Войной на Боевой Молот",[9946]="Чо'вар Погромщик",[9947]="Обратно к Рокагу",
    [9948]="Спасательная экспедиция",[9949]="Птичьи Глаза",[9950]="Птичьи Глаза",[9951]="Он следит за тобой!",
    [9952]="Геолог Бальморал",[9953]="Наблюдатель Нодак",[9954]="Выкуп за Корки",[9955]="Чо'вар Погромщик",
    [9956]="Разграбленный караван",[9957]="Что случилось в перелеске Кенария?",[9958]="Разведка укреплений",
    [9959]="Разведка укреплений",[9960]="Что случилось в перелеске Кенария?",
    [9961]="Что случилось в перелеске Кенария?",[9962]="Кольцо Крови: Хромоног",[9963]="Помощь от врага",
    [9964]="Помощь от врага",[9965]="Проявление веры",[9966]="Проявление веры",[9967]="Кольцо Крови: братья Блю",
    [9968]="Странная энергия",[9969]="Последние реагенты",[9970]="Кольцо Крови: Камнедар Выщербленный Повелитель",
    [9971]="Ответы в чащобе",[9972]="Кольцо Крови: Скрагат",[9973]="Кольцо Крови: чемпион клана Боевого Молота",
    [9974]="Последние реагенты",[9975]="Изначальная магия",[9976]="Изначальная магия",
    [9977]="Кольцо Крови: последнее испытание",[9978]="Любыми средствами",[9979]="Латрай Торговец Ветром",
    [9980]="Спасите Дейрома!",[9981]="Спасите Дугара!",[9982]="Его звали Алтруис...",[9983]="Его звали Алтруис...",
    [9984]="Хозяин Сокрытого Города",[9985]="Хозяин Сокрытого Города",[9986]="Сдержать араккоа",
    [9987]="Сдержать араккоа",[9988]="Лучший друг щеголя",[9989]="Неведомые духи",[9990]="Исследование Туурема",
    [9991]="Разведка",[9992]="Семена олембы",[9993]="Масло из семян олембы",[9994]="Что это такое?",
    [9995]="Что это такое?",[9996]="Нападение на лагерь Огнекрылых",[9997]="Нападение на лагерь Огнекрылых",
    [9998]="Беспокойные соседи",[9999]="Выиграть время",[10000]="Нежелательное присутствие",
    [10001]="Главный планировщик",[10002]="Посредник Огнекрылых",[10003]="Посредник Огнекрылых",
    [10004]="Терпение и понимание",[10005]="Вести для землепряда Тавгрена",[10006]="Вести для землепряда Тавгрена",
    [10007]="Ослабление врага",[10008]="Секреты Тероккара не покидают его границ",[10009]="Золото за тумаки",
    [10010]="Не так просто?",[10011]="Лагеря Легиона: уничтожены",[10012]="Планы орков Скверны",
    [10013]="Невидимая длань",[10014]="Проект лагеря Огнекрылых",[10015]="Проект лагеря Огнекрылых",
    [10016]="Хвосты лесных воргов",[10017]="Нехватка припасов",[10018]="Одежды духа волка",
    [10019]="Больше ядовитых желез",[10020]="Лекарство для Залии",[10021]="Возрождение Света",
    [10022]="Неуловимый Железнозуб",[10023]="Патриарх Железнозуб",[10024]="Видения Ворен'таля",
    [10025]="Больше глаз василисков",[10026]="Нарушение магического равновесия",
    [10027]="Нарушение магического равновесия",[10028]="Сосуды силы",[10029]="Зов духов",[10030]="Сбор останков",
    [10031]="Возвращение заблудших душ",[10033]="Награда за убитых костеклювов!",
    [10034]="Награда за убитых костеклювов!",[10035]="Торгос!",[10036]="Торгос!",[10037]="Без рыбалки",
    [10038]="Разговор с рядовым Виксом",[10039]="Разговор с разведчицей Нефтис",[10040]="Кто они?",[10041]="Кто они?",
    [10042]="Убить Совет Теней!",[10043]="Убить Совет Теней!",[10044]="Разговор с Великой матерью",
    [10045]="Компоненты зелья",[10046]="Через Темный портал",[10047]="Путь Славы",[10048]="Магическая пыль",
    [10049]="Магическая пыль",[10050]="Непреклонные духи",[10051]="Побег из лагеря Огнекрылых",
    [10052]="Побег из лагеря Огнекрылых",[10053]="Расправиться с Зет'Гором",[10054]="Надвигающийся рок",
    [10055]="Ничто не пропадет даром",[10056]="Припасы Кровавой Глазницы",[10057]="Солдатская верность",
    [10058]="Старый дар",[10059]="Расправиться с Зет'Гором",[10060]="Надвигающийся рок",[10061]="Непреклонные",
    [10062]="Солдатская верность",[10063]="Лига исследователей: что здесь делают гномы?",[10064]="Длань Аргуса",
    [10065]="Зеленая улица",[10066]="Тенета судьбы",[10067]="Смрадные водные духи",
    [10068]="Хранитель Колодца Соланиан",[10069]="Хранитель Колодца Соланиан",[10070]="Хранитель Колодца Соланиан",
    [10071]="Хранитель Колодца Соланиан",[10072]="Хранитель Колодца Соланиан",[10073]="Хранитель Колодца Соланиан",
    [10074]="Порошок кристалла Ошу'гуна",[10075]="Порошок кристалла Ошу'гуна",[10076]="Порошок кристалла Ошу'гуна",
    [10077]="Порошок кристалла Ошу'гуна",[10078]="Сжечь старье!",[10079]="Весь рудник ходуном",
    [10081]="Встреча с Матерью Кашур",[10082]="Покой предков",[10084]="Атака на Магеддон",[10085]="Навестить предков",
    [10086]="Я служу... Орде!",[10087]="Сжечь! Во имя Орды!",[10088]="Весь рудник ходуном",[10089]="Лагеря Легиона",
    [10090]="Планы Легиона",[10091]="Инструменты души",[10092]="Атака на Магеддон",[10093]="Храм Телхамат",
    [10094]="Кодекс Крови",[10095]="В самом сердце Лабиринта",[10096]="Спасение спорлоков",[10097]="Брат на брата",
    [10098]="Наследство Терокка",[10099]="Мозговой центр",[10100]="Мозговой центр",[10101]="Когда говорят духи",
    [10102]="Раскрытая тайна",[10103]="Донесение Зураю",[10104]="Опасения за судьбу Туурема",
    [10105]="Вести для Ракории",[10106]="Штурмовые укрепления",[10107]="Дипломатическая миссия",
    [10108]="Дипломатическая миссия",[10109]="Я их достану!",[10110]="Штурмовые укрепления",
    [10111]="Принеси мне яйцо!",[10112]="Личное одолжение",[10113]="Охотничий лагерь Эрнестуэя",
    [10114]="Охотничий лагерь Эрнестуэя",[10115]="Искажение Остротопи",[10116]="Разыскивается: вождь Муммаки!",
    [10117]="Разыскивается: вождь Муммаки!",[10118]="Разговор с Остротопью",[10119]="Через Темный портал",
    [10120]="Прибытие в Запределье",[10121]="Истребить Пылающий Легион",[10122]="Вблизи цитадели",
    [10123]="Лощина Вспышки Скверны",[10124]="Передовая застава: Останки Сквернобота",
    [10125]="Задание: разрушить связь",[10126]="Приказы боевого командира Некрогга",[10127]="Задание: Ослабить врага",
    [10128]="Спасти рядового Имариона",[10129]="Задание: Врата Муркет и Шаадраз",[10130]="Западный фланг",
    [10131]="План побега",[10132]="Колоссальная угроза",[10133]="Задание: убить гонца",
    [10134]="Ключ к разгадке алого кристалла",[10135]="Задание: доставить послание",[10136]="Безжалостные планы",
    [10137]="Провокация",[10138]="Кто отдает приказы?",[10139]="Разжаловать командира",
    [10140]="Путешествие в Оплот Чести",[10141]="Возрожденный Легион",[10142]="Путь Страданий",
    [10143]="Лагерь экспедиции",[10144]="Лишить Легион подкрепления!",[10145]="Mission: Sever the Tie UNUSED",
    [10146]="Задание: Врата Муркет и Шаадраз",[10147]="Задание: убить гонца",[10148]="Задание: доставить послание",
    [10149]="Задание: со щитом или на щите",[10150]="Вблизи цитадели",[10151]="Приказы боевого командира Некрогга",
    [10152]="Западный фланг",[10153]="Спасти разведчицу Маху",[10154]="План побега",[10155]="Провокация",
    [10156]="Кто отдает приказы?",[10157]="Разжаловать командира",[10158]="Припасы Кровавой Глазницы",
    [10159]="Очистить холм Колючего Клыка!",[10160]="Врага нужно знать в лицо",
    [10161]="В случае чрезвычайной ситуации...",[10162]="Задание: Косогор Бездны",[10163]="Задание: Косогор Бездны",
    [10164]="Все будет в порядке",[10165]="Жестокая вещь – конкуренция",[10166]="Память о Белостволе",
    [10167]="Аукиндон...",[10168]="Что видит душа",[10169]="Проиграть с честью",
    [10170]="Возвращение к Великой Матери",[10171]="Безутешный Вождь",[10172]="Надежды нет",
    [10173]="Посох верховного мага",[10174]="Проклятие Аметистовой башни",[10175]="Тралл, сын Дуротана",
    [10176]="Страж Ар'келос",[10177]="В Аукиндоне неспокойно",[10178]="Найти шпиона То'гуна!",
    [10179]="Смотритель Кирин'Вара",[10180]="Неудержимый",[10182]="Боевой маг Датрик",[10183]="В Зону 52",
    [10184]="Зловещие останки",[10185]="Участь хуже, чем смерть",[10186]="Тебя наняли!",
    [10187]="Послание для верховного мага",[10188]="Печать Краса",[10189]="Манагорн Б'наар",
    [10190]="Перезарядка батарей",[10191]="Робот модели V жив!",[10192]="Компендиум Краса",[10193]="Высокие цели",
    [10194]="Незаметный полет",[10195]="Наемник видит, наемник делает",[10196]="Больше перьев араккоа",
    [10197]="Убедительная маскировка",[10198]="Сбор информации",[10199]="Дополнительная сила",
    [10200]="Возвращение к Талодиену",[10201]="Момент истины",[10202]="Дезертир",
    [10203]="Захват бесценного оборудования",[10204]="Кристаллы камня Крови",[10205]="Астральный налетчик Несаад",
    [10206]="В погоне за технологиями",[10207]="Forward Base: Reaver's Fall REUSE",
    [10208]="Лишить Легион подкрепления!",[10209]="Трофей призывателя Кантина",[10210]="А'дал",[10211]="Город Света",
    [10212]="Герой маг'харов",[10213]="Найти место крушения",[10214]="Весь рудник ходуном",
    [10216]="Прежде всего - безопасность!",[10218]="Someone Else's Hard Work Pays Off",[10220]="Заставь их слушать",
    [10221]="Доктор Бум!",[10222]="Гарнизон Ярости Солнца",[10223]="Покончить с Даэллисом",
    [10224]="Эссенция для двигателей",[10225]="Рапорт главному инженеру",[10226]="Извлечение силы стихии",
    [10227]="Я вижу мертвых дренеев",[10228]="Иезекииль",[10229]="Секрет фолианта",[10230]="Боевой рог",
    [10231]="Какая книга? Не вижу никакой книги",[10232]="Легион – на мусор!",[10233]="Пожар в форте Ярости Солнца",
    [10234]="Что одному демону мусор...",[10235]="Коготь Рока? Вырвать с мясом!",
    [10236]="Гадость это ваше Запределье!",[10237]="Предупредить Зону 52!",[10238]="Каково работать на гоблинов",
    [10239]="Потенциальный источник энергии",[10240]="Постройка периметра",
    [10241]="Отвлекающий маневр в манагорне Б'наар",[10242]="Застава Хребтолома",[10243]="Технология наару",
    [10244]="Учи матчасть!",[10245]="Описание панели управления Б'наара",[10246]="Нападение на манагорн Коруу",
    [10247]="Вомиза, доктор псевдотехнических наук",[10248]="Ты, робот",[10249]="Обратно к командующему!",
    [10250]="Кровавая месть",[10251]="Великий замысел господина?",[10252]="Посмотри в глаза мертвым",
    [10253]="Левиксус Призыватель Душ",[10254]="Командир армии Данат",[10255]="Проверка противоядия",
    [10256]="Найти Хранителя Ключей",[10257]="Захват краеугольного камня",[10258]="Честь Павших",
    [10259]="Битва в Проломе",[10260]="Пустолог Медноклеппер",[10261]="Разыскивается: аннигиляторный сервопривод!",
    [10262]="Груда духов Астрала",[10263]="Содействие Консорциуму",[10264]="Содействие Консорциуму",
    [10265]="Добыча артефакта для Консорциума",[10266]="Запрос о содействии",[10267]="Изъятие по праву",
    [10268]="Аудиенция у принца",[10269]="Триангуляция: точка первая",[10270]="Нескромное предложение",
    [10271]="Деловая активность",[10272]="Многообещающее начало",[10273]="Пустые хлопоты",
    [10274]="Безопасность Небесной гряды",[10275]="Триангуляция: точка вторая",[10276]="Полный треугольник",
    [10277]="Пещеры Времени",[10278]="Астральные провалы",[10279]="Логово господина",
    [10280]="Специальный груз в город Шаттрат",[10281]="Формальное представление",[10282]="Старый Хилсбрад",
    [10283]="План Тареты",[10284]="Побег из Дарнхольда",[10285]="Возвращение к Андорму",[10286]="Тайна Арелиона",
    [10287]="Кем оказалась любовница",[10288]="Прибытие в Запределье",[10289]="Путешествие в Траллмар",
    [10290]="В поисках фаралита",[10291]="Донесение Назгрелу",[10292]="Больше энергии!",
    [10293]="Попасть на главную жилу",[10294]="Пустынный обрыв",[10295]="Сила бездны",[10296]="Черные топи",
    [10297]="Открытие Темного портала",[10298]="Герой драконьего племени",[10299]="Отключить манагорн Б'наар",
    [10300]="Восстановление посоха",[10301]="Открыть Компендиум",[10302]="Неустойчивые мутации",[10303]="Эльфы крови",
    [10304]="Воздаятель Алдар",[10305]="Клятвопреступница Белмара",[10306]="Кудесник Люминрат",
    [10307]="Кольен Повелитель Льда",[10308]="Еще одна группа духов Астрала",
    [10309]="Это сквернобот, но у него есть сердце!",[10310]="Саботаж в портале",[10311]="Дризья нужна твоя помощь",
    [10312]="Анналы Кирин'Вара",[10313]="Измерение энергии Искажения",[10314]="Длительные подозрения",
    [10315]="Нейтрализовать чародеев Пустоты",[10316]="В поисках доказательств",[10317]="Покончить со штейгером",
    [10318]="Покончить с Подчинителем",[10319]="Захватить талисман",[10320]="Уничтожить Набериуса!",
    [10321]="Отключить манагорн Коруу",[10322]="Отключить манагорн Даро",[10323]="Отключить манагорн Ара",
    [10324]="Великая охота на лунных оленей",[10325]="Знаки Кил'джедена",[10326]="Больше знаков Кил'джедена",
    [10327]="Знак Кил'джедена",[10328]="Инструкции Ярости Солнца",[10329]="Отключить манагорн Б'наар",
    [10330]="Отключить манагорн Коруу",[10331]="Необходимые инструменты",[10332]="Мастер-кузнец Ронсус",
    [10333]="Помощь Мамаше Колесун",[10334]="Колокольчик для коровы",[10335]="Исследование руин",
    [10336]="Приспешники Кулутаса",[10337]="Когда коровы возвращаются домой",[10338]="Отключить манагорн Даро",
    [10339]="Братство Эфириум",[10340]="Парящая застава",[10341]="Лежачего не бьют – лежачего пинают",
    [10342]="Добыча кожи глиношкурых",[10343]="Бесконечное вторжение",[10344]="Командир звена Грифонгар",
    [10345]="Усеял мертвыми костями...",[10346]="Возвращение на Косогор Бездны",
    [10347]="Возвращение на Косогор Бездны",[10348]="Новые возможности",[10350]="Бехомат",
    [10351]="Целительная сила природы",[10352]="Пожертвование: шерсть",[10353]="Арконус Ненасытный",
    [10354]="Пожертвование: шелк",[10355]="Иссохшее тело",[10356]="Пожертвование: магическая ткань",
    [10357]="Пожертвование: руническая ткань",[10358]="Больше рунической ткани",[10359]="Пожертвование: шерсть",
    [10360]="Пожертвование: шелк",[10361]="Пожертвование: магическая ткань",[10362]="Пожертвование: руническая ткань",
    [10364]="Кедмос",[10366]="Джоль",[10367]="Предатель среди нас",[10368]="Старейшины Отребья",
    [10369]="Наследие Арзета",[10372]="Деликатная просьба",[10373]="Призыв к оружию: Чумные земли!",
    [10374]="Призыв к оружию: Чумные земли!",[10379]="Прикосновение слабости",[10380]="Темный пакт",
    [10381]="Нет больше Алдора",[10382]="Отправка на фронт",[10383]="Хлебные крошки!",
    [10384]="Данные Братства Эфириум",[10385]="Риск поражения мозга – высокий",[10386]="Гроза скверноботов",
    [10387]="Гроза скверноботов",[10388]="Назад в Траллмар",[10389]="Тьма и агония",
    [10390]="Лагерь Легиона: Магеддон",[10391]="Пушки Ярости",[10392]="Дверь в Бездну",[10393]="Коварные планы",
    [10394]="Уничтожение – лагерь Легиона: Магеддон",[10395]="Темное послание",[10396]="Враг моего врага...",
    [10397]="Точка вторжения: Аннигилятор",[10398]="Возвращение в Оплот Чести",[10399]="Сердце тьмы",
    [10400]="Владыка",[10401]="Задание: со щитом или на щите",[10403]="Наладу",[10404]="Против Легиона",
    [10405]="С-А-Б-О-Т-А-Ж",[10406]="Передать послание",[10407]="Тень Сокретара",[10408]="Соправитель Салхадаар",
    [10409]="Удар по Легиону",[10410]="Помощь Ишаны",[10411]="Слава электрошоку!",[10412]="Перстни Огнекрылых",
    [10413]="Ужасы загрязнения",[10414]="Перстень Огнекрылых",[10415]="Больше перстней Огнекрылых",
    [10416]="Преобразование силы",[10417]="Провести диагностику",[10418]="Покончить с вредителями",
    [10419]="Чародейские фолианты",[10420]="Очищающий Свет",[10421]="Латные перчатки Скверны",
    [10422]="Капитан Тиралиус",[10423]="В Штормовую Вершину",[10424]="Диагноз: критический",
    [10425]="Побег с полигона",[10426]="Растительность заповедников",[10427]="Животные заповедников",
    [10428]="Пропавший рыбак",[10429]="Когда природа заходит слишком далеко",[10430]="Испытание прототипа",
    [10431]="Помощь извне",[10432]="Надежное свидетельство",[10433]="Поддерживая видимость",
    [10434]="Динамический дуэт",[10435]="Сбор деталей",[10436]="Все чисто!",[10437]="Рецепт уничтожения",
    [10438]="На крыльях Пустоты",[10439]="Пространствус Всепоглощающий",[10440]="Готово!",
    [10441]="Торговля по мелочам",[10442]="Помощь Кенарийской заставе",[10443]="Помощь Кенарийской заставе",
    [10444]="Послание для Заставы Аллерии",[10445]="Сосуды Вечности",[10446]="Финальный код",[10447]="Финальный код",
    [10448]="Донесение в лагерь Камнеломов",[10449]="Аптекарь Зелана",[10450]="Кровь клана Костеглодов",
    [10451]="Спастись из водохранилища Змеиных Колец",[10455]="Угроза хищников",[10456]="Волчья напасть",
    [10457]="Защитить свой дом",[10458]="Разъяренные бесы пламени и земли",
    [10459]="Почтительное отношение Кенарийской экспедиции",[10460]="Посвящение в защитники",
    [10461]="Посвящение в целители",[10462]="Посвящение в герои",[10463]="Посвящение в мудрецы",
    [10464]="Обет мудреца",[10465]="Обет целителя",[10466]="Обет героя",[10467]="Обет защитника",
    [10468]="Клятва мудреца",[10469]="Клятва целителя",[10470]="Клятва защитника",[10471]="Клятва защитника",
    [10472]="Договор мудреца",[10473]="Договор целителя",[10474]="Договор героя",[10475]="Договор защитника",
    [10476]="Лютые враги",[10477]="Боевые ожерелья",[10478]="Боевые ожерелья!",[10479]="Покажи свою силу",
    [10480]="Разъяренные бесы воды",[10481]="Разъяренные бесы воздуха",[10482]="Падальщики орков Скверны",
    [10483]="Дурные предзнаменования",[10484]="Проклятые талисманы",[10485]="Воевода клана Кровавой Глазницы",
    [10486]="Угроза хищников",[10487]="Пыльца волшебных драконов",[10488]="Защитить свой дом",[10491]="Зов воздуха",
    [10492]="Серьезное предложение",[10493]="Серьезное предложение",[10494]="Справедливое вознаграждение",
    [10495]="Справедливое вознаграждение",[10496]="Прощальные слова Антиона",[10497]="Прощальные слова Антиона",
    [10498]="Сладкое – на закуску",[10501]="Альянсу нужна твоя помощь!",[10502]="Клан Кровавого Молота",
    [10503]="Угроза Камнерогов",[10504]="Огры из клана Камнерогов",[10505]="Клан Кровавого Молота",
    [10506]="Тяжелая ситуация",[10507]="Поворотная точка",[10508]="Дар для Ворен'таля",[10509]="И все ради славы",
    [10510]="В дренетистовые копи",[10511]="Странное пиво",[10512]="Пусть Камнероги упьются!",
    [10513]="Оронок Горемычный",[10514]="Кем только я не был...",[10515]="Усвоенный урок",[10516]="Вещи Поборницы",
    [10517]="Горр'Дим, твой час пробил...",[10518]="Водружение знамени",[10519]="Код Проклятия – правда и миф",
    [10520]="Помощь верховному друиду Оленьему Шлему",[10521]="Гром'тор, сын Оронока",
    [10522]="Код Проклятия: Вклад Гром'тора",[10523]="Код Проклятия: Первый Фрагмент",
    [10524]="Сокровища клана Громоборцев",[10525]="Путеводный огонек",[10526]="Громовая пика",
    [10527]="Ар'тор, сын Оронока",[10530]="Путь охотника",[10531]="Битва за Низину Арати",[10534]="Возвращение домой",
    [10535]="Ресурсы Низины Арати",[10537]="Лон'горон, лук Горемычного",[10539]="Возвращение домой",
    [10540]="Код Проклятия: Вклад Ар'тора",[10541]="Код Проклятия – Второй фрагмент",
    [10542]="У меня сперли кальян и выпивку!",[10543]="Гримнок и Коргаах, я за вами!",
    [10544]="Чума на оба ваших клана!",[10545]="Бочонок клана Камнерогов",[10546]="Борак, сын Оронока",
    [10548]="Горькая правда",[10550]="Пучок кровопийки",[10551]="Присяга верности Алдорам",
    [10552]="Присяга верности Провидцам",[10553]="Ворен'таль Предсказатель",[10554]="Ишана",[10555]="Недомогание",
    [10556]="Рисунки",[10557]="Испытательный полет: Конденсаторий зефира",
    [10558]="Уважительное отношение Оплота Чести",[10559]="Уважительное отношение Траллмара",
    [10560]="Почтительное отношение Ша'тар",[10561]="Уважение Хранителей Времени",[10562]="Окружены!",
    [10563]="В форт Легиона",[10564]="Перебей инферналов!",[10565]="Камни Векх'ниров",[10566]="Пробы и ошибки",
    [10567]="Создание подвески",[10568]="Таблички Баа'ри",[10569]="Развалины Скет'лона",[10570]="Охота на Посла",
    [10571]="Старец Орону",[10572]="Сборка бомбы",[10573]="Кузница Смерти",[10574]="Осквернители из клана Пеплоустов",
    [10575]="Клеть Стражницы",[10576]="Уловки Призрачной Луны",[10577]="Чего Иллидан хочет, Иллидан получит...",
    [10578]="Код Проклятия – Вклад Борака",[10579]="Код Проклятия – Третий фрагмент",
    [10580]="Куда подевались эти клятые гномы?",[10581]="Иди по крошечкам!",[10582]="Приспешники Совета Теней",
    [10583]="Судьба Фланиса",[10584]="Спасти преобразователи энергии!",[10585]="Чертог Призыва",
    [10586]="Смерть вестнику войны!",[10587]="Тренировочная площадка Карабора",[10588]="Код Проклятия",
    [10593]="Древнее зло",[10594]="Калибровка резонансной частоты",[10595]="Окружены!",[10596]="В форт Легиона",
    [10597]="Сборка бомбы",[10598]="Перебей инферналов!",[10599]="Кузница Смерти",[10600]="Приспешники Совета Теней",
    [10601]="Судьба Кагроша",[10602]="Чертог Призыва",[10603]="Смерть вестнику войны!",[10605]="Призыв Карендина",
    [10606]="Искусство ухода за скверноботом",[10607]="Шепот Бога-ворона",[10608]="Ясно как день!",
    [10609]="Что было первым, дракон или яйцо?",[10611]="Искусство ухода за скверноботом",
    [10612]="Машина для убийства",[10613]="Машина для убийства",[10614]="Шепот ветра",[10615]="Чащоба Рууан",
    [10617]="Коконы шелкокрыла",[10618]="Нежнейшие крылья",[10619]="Клан Пеплоустов",[10620]="Угроза горного хребта",
    [10621]="Осколок погибели Иллидари",[10622]="Доказательство верности",[10623]="Осколок погибели Иллидари",
    [10624]="История про привидений...",[10625]="Спектроскоп",[10626]="Сдать оружие!",[10627]="Сдать оружие!",
    [10628]="Акама",[10629]="Шизанутая работенка",[10630]="Рядом с Траллмаром",[10632]="Точи зубы!",
    [10633]="Терон Кровожад – Правда и Вымысел",[10634]="Прорицание: Броня Кровожада",
    [10635]="Прорицание: Плащ Кровожада",[10636]="Прорицание: буздыхан Кровожада",[10638]="NOT A QUEST",
    [10639]="Терон Кровожад, то есть я...",[10640]="Алтруис",[10641]="Против Легиона",[10642]="Дух из машины",
    [10643]="Вестники Призрачной Луны",[10644]="Терон Кровожад – Правда и Вымысел",
    [10645]="Терон Кровожад, то есть я...",[10646]="Ученик Иллидана",
    [10647]="Разыскивается: Увурос, бич долины Призрачной Луны",
    [10648]="Разыскивается: Увурос, бич долины Призрачной Луны",[10649]="Книга Имен Скверны",
    [10650]="Возвращение к Алдорам",[10651]="Варедиса нужно остановить!",[10652]="В тылу врага",
    [10653]="Знаки Саргераса",[10654]="Больше знаков Саргераса",[10655]="Знак Саргераса",
    [10656]="Перстни Ярости Солнца",[10657]="Оседлать молнию",[10658]="Больше перстней Ярости Солнца",
    [10659]="Перстень Ярости Солнца",[10660]="Что за странные создания?",[10661]="Умопотрошительно!",
    [10662]="Кузнец–отшельник",[10663]="Кузнец–отшельник",[10664]="Дополнительные материалы",
    [10665]="Новинка из Механара",[10666]="Лексикон демоника",[10667]="Суглинок из Нижнего мира",
    [10668]="Против иллидари",[10669]="Вопреки всему",[10670]="Слеза Матери-Земли",[10671]="Не только фунт мяса",
    [10672]="Честно говоря, это – бред!",[10673]="Хребтоскверн Старший",[10674]="Ловля фантастического света",
    [10675]="Попомните гномскую доброту!",[10676]="Проклятие иллидари",[10677]="Второе блюдо...",
    [10678]="Гвоздь программы",[10679]="Закалка Меча",[10680]="Рука Гул'дана",[10681]="Рука Гул'дана",
    [10682]="Время для переговоров...",[10683]="Таблички Баа'ри",[10684]="Старец Орону",
    [10685]="Осквернители из клана Пеплоустов",[10686]="Клеть Стражницы",[10687]="Тренировочная площадка Карабора",
    [10688]="Необходимая уловка",[10689]="Алтруис",[10690]="Мать логова",[10691]="Возвращение к Провидцам",
    [10700]="Десять рекомендательных жетонов",[10701]="Низвергнуть Глыбня Пустоты",[10702]="Наряд вне очереди",
    [10703]="Зачистка",[10704]="Как проникнуть в Аркатрац",[10705]="Провидец Адало",[10706]="Таинственное знамение",
    [10707]="Терраса Ата'мала",[10708]="Обещание Акамы",[10709]="Воссоединение",
    [10710]="Испытательный полет: Звенящий гребень",[10711]="Испытательный полет: лагерь Разаана",
    [10712]="Испытательный полет: чащоба Рууан",[10713]="...и время действовать",[10714]="На крыльях Духа",
    [10715]="Прогулка в Беспокойную лощину",[10716]="Test Flight: Raven's Wood <needs reward>",
    [10717]="Вор у вора...",[10718]="У духов есть голоса",[10719]="Где записка?",[10720]="Самые маленькие создания",
    [10721]="Подложим Груллоку свинью",[10722]="Встреча в пещере Крыла Тьмы",[10723]="Горгром Драконоед",
    [10724]="Пленник Камнерогов",[10725]="Аметистовое Око в восхищении",[10726]="Аметистовое Око в восхищении",
    [10727]="Аметистовое Око в восхищении",[10728]="Аметистовое Око в восхищении",[10729]="Маг из Аметистового Ока",
    [10730]="Исцелитель из Аметистового Ока",[10731]="Убийца из Аметистового Ока",
    [10732]="Защитник из Аметистового Ока",[10733]="Путь Аметистового Ока",[10734]="Путь Аметистового Ока",
    [10735]="Путь Аметистового Ока",[10736]="Путь Аметистового Ока",[10737]="Разрешение учителя",
    [10738]="Выдающиеся заслуги",[10739]="Выдающиеся заслуги",[10740]="Выдающиеся заслуги",
    [10741]="Выдающиеся заслуги",[10742]="Перед выстрелом",[10744]="Вести о Победе",[10745]="Вести о Победе",
    [10747]="Дракончики Культа Змея",[10748]="Да сгинет Макснар!",[10749]="Яд барона Черногрива",
    [10750]="Путь Завоевания",[10751]="Перерезанный путь",[10752]="Вперед, в Ясеневый лес",[10753]="Зачистка пустоши",
    [10754]="Вход в цитадель",[10755]="Вход в цитадель",[10756]="Великий мастер Рохок",[10757]="Просьба Рохока",
    [10758]="Жарче, чем в пекле",[10759]="Найти дезертира",[10760]="Развалины Скет'лона",[10761]="Найти дезертира",
    [10762]="Великий Мастер Болтуй",[10763]="Просьба Болтуя",[10764]="Жарче, чем в пекле",[10765]="Война Миров",
    [10766]="Точка вторжения: Катаклизм",[10767]="Точка вторжения: Катаклизм",[10768]="Гербовые накидки Иллидари",
    [10769]="Удар исподтишка",[10770]="Угольки",[10771]="Из пепла",[10772]="Путь Завоевания",
    [10773]="Перерезанный путь",[10774]="Великан плюс эльфийка равно...",[10775]="Гербовые накидки Иллидари",
    [10776]="Удар исподтишка",[10777]="Тотем Азгара",[10779]="Путь охотника",[10780]="Перья Скет'лона",
    [10781]="Битва у Кровавого дозора",[10782]="Зарядка набалдашника",[10783]="Барон Черногрив",
    [10784]="Уничтожить лагерь Кровавого Молота!",[10785]="Ловушка!",[10790]="Возвращение к Ган'рулу Кровавому Глазу",
    [10791]="Приветствие духа Волка",[10792]="Сжечь Зет'Гор!",[10794]="Разбойники Изувеченной Длани",
    [10795]="Встреча с Доргоком",[10796]="Уничтожить лагерь Кровавого Молота!",[10797]="Благоволение гронна",
    [10798]="Визит к барону",[10799]="Прогулка в Беспокойную лощину",[10800]="Спи спокойно, гронн",[10801]="Ловушка!",
    [10802]="Горгром Драконоед",[10803]="Резня в Камен'моке",[10804]="Доброта",[10805]="Резня в логове Груула",
    [10806]="Перед выстрелом",[10807]="Сломленные из племени Пеплоустов",[10808]="Крах темного конклава",
    [10809]="Разыскивается: повелитель воргов Крууш",[10810]="Поврежденная маска",[10811]="Поиски Нельтараку",
    [10812]="Тайная маска",[10813]="Очи Гриллока",[10814]="История Нельтараку",
    [10815]="Записи Вал'зарека: Предвестье Войны",[10816]="Восстановление Святых земель",[10817]="Великое воздаяние",
    [10818]="Барон Черногрив желает вас лицезреть",[10819]="Респиратор Искаженных",[10820]="Обмануть врага",
    [10821]="Уволена!",[10822]="Перстень Ярости Солнца",[10823]="Больше перстней Ярости Солнца",
    [10824]="Перстни Ярости Солнца",[10825]="Тайна сферы",[10826]="Знаки Саргераса",[10827]="Больше знаков Саргераса",
    [10828]="Знак Саргераса",[10829]="Древоствол должен знать!",[10833]="Обучение шитью из тенеткани",
    [10834]="Гриллок \"Пустой Глаз\"",[10835]="Аптекарь Антонивич",[10836]="Переполох в крепости Драконьей Пасти",
    [10837]="На кряж Крыльев Пустоты!",[10838]="Демонический кристалл",
    [10839]="Гнездовье Скит: Темный камень Терокка",[10840]="Гробница Света",[10841]="Мстительный предвестник",
    [10842]="Мстительные души",[10843]="С незапамятных времен...",[10844]="Лагерь Легиона: Злоба",
    [10845]="Убить мать драконов",[10846]="Как понять Мок'Натал",[10847]="Глаза Скеттиса",
    [10848]="Гнездовье Рейз: неживое зло",[10849]="Поиски Киррика",[10850]="Газ хаоса в двигателе",
    [10851]="Тотем врага моего",[10852]="Пропавшие друзья",[10853]="Призыв духов",[10854]="Силы Нельтараку",
    [10855]="Сквернобот – нет, спасибо!",[10856]="Наилучшая защита",[10857]="Телепортируй это!",[10858]="Каринаку",
    [10859]="Собрать шары",[10860]="Лакомства Мок'Натал",[10861]="Гнездовье Литик: превентивный удар",
    [10862]="Сдаться Орде",[10863]="Тайны араккоа",[10864]="Урожай душ",[10865]="Доложить Леороксу!",
    [10866]="Зулухед Измученный",[10867]="Ответ будет только один",[10868]="Тропа войны араккоа",
    [10869]="Уменьшить стаю",[10870]="Союзник Крыльев Пустоты",[10871]="Союзник Крыльев Пустоты",
    [10872]="Зулухед Измученный",[10873]="Захваченные в ночи",[10874]="Гнездовье Шалас: сигнальные огни",
    [10875]="Донесение Назгрелу",[10876]="Вступить в цитадель",[10877]="Реликвия Ужаса",[10878]="До наступления тьмы",
    [10879]="Нападение Скеттиса",[10880]="Распоряжения заговорщиков",[10881]="Гробница Тени",[10882]="Вестник Рока",
    [10883]="Ключ Урагана",[10884]="Испытание наару: милосердие",[10885]="Испытание наару: сила",
    [10886]="Испытание наару: упорство",[10887]="Побег из гробницы",[10888]="Испытание наару: Магтеридон",
    [10892]="Имперские латы",[10893]="За всем стоит Длиннохвостка",[10894]="Страж Драконьего черепа",
    [10895]="Сжечь Зет'Гор!",[10897]="Мастер зелий",[10899]="Мастер трансмутации",[10900]="Медальон Вайш",
    [10902]="Мастер эликсиров",[10903]="Возвращение в Оплот Чести",[10907]="Мастер трансмутации",
    [10908]="Поговорите с Рилаком Освобожденным",[10909]="Духи Скверны",[10910]="Врата Смерти",
    [10911]="Открыть огонь!",[10912]="Псарь",[10913]="Недостойные похороны",[10914]="Требуется герой",
    [10915]="Падший экзарх",[10916]="Откопать благословенные четки",[10917]="Затруднительное положение изгнанника",
    [10918]="Больше перьев",[10919]="Собачья радость",[10920]="За павших",[10921]="Тероккарантул",
    [10922]="Костяные раскопки",[10923]="Зло приближается",[10924]="Кровная м... есть!",[10925]="Зло приближается",
    [10926]="Обратно в лагерь Ша'тар",[10927]="Убийство пауков",[10928]="Убийство пауков",[10929]="Барабанный бой",
    [10934]="Возвращение в Луносвет",[10935]="Экзорцизм над полковником Джулсом",[10936]="Тебя ищет Троллебой",
    [10943]="Детская неделя",[10945]="Хч'уу и народ грибов",[10946]="Коварство Пеплоустов",
    [10947]="Артефакт из прошлого",[10948]="Пленная душа",[10956]="Трон наару",[10957]="Искупление Пеплоустов",
    [10958]="Найти Пеплоустов",[10968]="Зов предсказателя",[10969]="В поисках Амира",[10970]="Миссия милосердия",
    [10971]="Секреты Эфириума",[10972]="Каталог бирок пленников Эфириума",[10973]="Тысяча миров",
    [10974]="Стазисные камеры Баш'ира",[10975]="Очищение камер Баш'ира",[10976]="Знак короля нексуса",
    [10980]="Книга Ворона",[10981]="Личная палата принца Шаффара",[10982]="Око Харамада",[10983]="Мог'дорг Мудрый",
    [10984]="Разговор с огром",[10988]="Вороньи камни",[10994]="В поисках лунного камня",
    [10995]="У Груллока два черепа",[10996]="Сундук с сокровищами Маггока",[10997]="Даже у гроннов есть штандарты",
    [10998]="Черно(книжн)ый бизнес",[11001]="Изгнание бога-ворона",[11002]="Падение Магтеридона",
    [11003]="Падение Магтеридона",[11004]="Мир Теней",[11005]="Тайны жрецов Когтя",[11006]="Больше теневой пыли",
    [11007]="Кель'тас и зеленеющая сфера",[11008]="Огонь над Скеттисом",[11009]="Огрские небеса",
    [11011]="Вечная бдительность",[11012]="Клятва в верности Крыльям Пустоты",[11013]="В услужении у Иллидари",
    [11014]="Задание десятника",[11015]="Кристаллы Крыльев Пустоты",[11016]="Шкуры живодеров-пустокопов",
    [11017]="Пыльца пустопраха",[11018]="Хаотитовая руда",[11019]="Друг в тылу врага",[11020]="Медленная смерть",
    [11021]="Альманах Ишааля",[11022]="Разговор с Мог'доргом",[11023]="Еще разок задать им жару!",
    [11024]="Союзник в Нижнем городе",[11025]="Кристаллы",[11026]="Гони демонов!",[11027]="Есть у тебя темная руна?",
    [11028]="Оставшееся время",[11029]="Потрепанная маскировка",
    [11030]="Наш мальчик хочет быть следопытом Стражи Небес",
    [11031]="Перестать быть верховным магом из Аметистового Ока",
    [11032]="Перестать быть защитником из Аметистового Ока",[11033]="Перестать быть убийцей из Аметистового Ока",
    [11034]="Перестать быть исцелителем",[11035]="Недружелюбные небеса",[11036]="Еще один пункт долой!",
    [11037]="Странное видение",[11038]="Помощь экзарху Орелису",[11039]="Отчет патрону шпионов Талодиену",
    [11040]="Детали для ведущего ракетостроителя",[11041]="Неоконченное дело",[11042]="Таинственное видение",
    [11043]="Усовершенствованный грифон",[11044]="Страшные видения",[11045]="Зорус Ревнитель",
    [11046]="Главный аптекарь Хильдегард",[11047]="Просьба ученика",[11048]="Рапорт Крогхана",[11049]="Большая Охота",
    [11050]="Собрать их все!",[11051]="Демонов – долой!",[11052]="Обещание Акамы",[11053]="Новое назначение",
    [11054]="Ты – инспектор: как делать все правильно",[11055]="Ботиранг: лекарство для нерадивых батраков",
    [11056]="Просьба Хаззика",[11057]="Огрское подполье",[11058]="Апекситовая реликвия",[11059]="Страж монумента",
    [11060]="Кристалл с темными рунами",[11061]="Отцовский долг",[11062]="Застава Стражи Небес",
    [11063]="Заработай крылья",[11064]="Гонки Драконьей Пасти: баллада о старине Макстаре",
    [11065]="Ловим летучих скатов!",[11066]="Нам нужно больше летучих скатов!",
    [11067]="Гонки Драконьей Пасти: Троп Смраднорыг",[11068]="Гонки Драконьей Пасти: Корлок Ветеринар",
    [11069]="Гонки Драконьей Пасти: командир звена Ромеон",[11070]="Гонки Драконьей Пасти: командир звена Маэстр",
    [11071]="Гонки Драконьей Пасти: капитан Небокрушитель",[11072]="Кровные враги",[11073]="Падение Терокка",
    [11074]="Кровные враги",[11075]="Копи Крыльев Пустоты",[11076]="Собрать по кусочкам...",
    [11077]="Драконы – это не самое страшное",[11078]="В небесах останется только один!",
    [11079]="Бич Скверны для Гахка",[11080]="Излучение реликвии",[11081]="Восстание в племени Темной Крови",
    [11082]="Искатель Истины",[11083]="Спятившие и очень опасные...",[11084]="Стой прямо, капитан!",
    [11085]="Побег из Скеттиса",[11086]="Разрушение сумеречного портала",[11089]="Пушка души Рет'хедрона",
    [11090]="Покорить Покорителя",[11091]="Особая благодарность",[11092]="Приветствую тебя, Командир!",
    [11093]="Пропитание для скатов Пустоты",[11094]="Всех убей, один останься!",[11095]="Командор Хобб",
    [11096]="Угроза извне",[11097]="Самая Опасная Ловушка",[11098]="В Скеттис!",[11099]="Всех убей, один останься!",
    [11100]="Командор Аркус",[11101]="Самая Опасная Ловушка",[11102]="Бомбардировка",[11103]="Отказ мудреца",
    [11104]="Перестать быть исцелителем",[11105]="Отказ героя",[11106]="Отказ защитника",
    [11107]="Склонитесь перед верховным господином",[11108]="Владыка Иллидан Ярость Бури",
    [11109]="Кобальтовый дракон Пустоты Хорус",[11110]="Лиловый дракон Пустоты Малфас",
    [11111]="Ониксовый дракон Пустоты Ониксиен",[11112]="Лазурный дракон Пустоты Сураку",
    [11113]="Пурпурный дракон Пустоты Воранаку",[11114]="Зои, изумрудный дракон Пустоты",
    [11118]="Розовые элекки на марше",[11122]="Туда и обратно",[11123]="Исследование пепелища",
    [11124]="Исследование пепелища",[11126]="Чужой среди своих",[11128]="Пропагандистская война",
    [11129]="Пропал Кайл!",[11131]="Гаси пожар!",[11132]="Все обещаешь и обещаешь",
    [11133]="Дискредитация вражеской агентуры",[11135]="Всадник без головы",[11136]="Тревожные события",
    [11137]="Братство Справедливости в Пылевых топях?",[11138]="Ренн Макгилл",[11139]="Старое водолазное снаряжение",
    [11140]="Вернуть груз!",[11141]="Джайна должна быть в курсе",[11142]="Исследование острова Алькац",
    [11143]="Мрачные выводы",[11144]="Подтвержденные подозрения",[11145]="Пленники Зловещего Тотема",
    [11146]="Ловля ящеров",[11147]="Боевые ящеры",[11148]="Оружие племени Зловещего Тотема",[11149]="Помощь Табеты",
    [11150]="Уничтожение заставы Дикого Рога",[11151]="Справедливая месть за Хьялей",[11152]="Обрести покой",
    [11153]="Прорвать блокаду",[11154]="Пусть обделаются от страха!",[11155]="Снова суп из черпорога?",
    [11156]="Налетчики Дикого Рога",[11157]="В тисках зла",[11158]="Перья Кровавой Топи",
    [11159]="Духи в руинах деревни Каменного Молота",[11160]="Знамя Каменного Молота",[11161]="Сущность вражды",
    [11162]="Бросить вызов черным драконам",[11163]="Тайная Сестрица",[11164]="Клыкастые всадники",
    [11165]="Троль из троллей",[11166]="Крестом на карте обозначена... твоя смерть!",[11167]="Новая чума",
    [11168]="Добавить крепости",[11169]="Оружие племени Зловещего Тотема",[11170]="Испытания на море",
    [11171]="Повелитель Проклятий? Пффф!",[11172]="Крушение дирижабля",[11173]="Подмена реактива",
    [11174]="Профилактика коррозии",[11175]="Дочка моя",[11176]="Присматривая за работой",
    [11177]="Отшельник из сторожки \"Болотный огонек\"",[11178]="Кровь Вождя",[11179]="У Финлея кишка тонка",
    [11180]="Что таится на Ведьмином холме?",[11181]="Ведьмина погибель",[11182]="В поисках первопричины",
    [11183]="Очищение Ведьминого холма",[11184]="Разыскивается: Кровокоготь Ненасытный",[11185]="Письмо аптекаря",
    [11186]="Свидетельство предательства?",[11187]="Маг-лейтенант Малистер",[11188]="Минус на минус",
    [11189]="В последний раз",[11190]="К каждой пушке затычка",[11191]="Этот старый маяк",[11192]="Жир крепкозуба",
    [11193]="Подлые обитатели глубин",[11194]="Так это правда?",[11195]="Игра в куклы",[11196]="TEMP X",
    [11198]="Сразить Тетура!",[11199]="Доклад разведчика Ноулса",[11200]="Не просто совпадение",
    [11201]="Замысел племени Зловещего Тотема",[11202]="Задание: вечный огонь",[11203]="Найти Табету",
    [11204]="Возвращение к Крогу",[11205]="Уничтожение заставы Дикого Рога",[11206]="Акт правосудия",
    [11207]="Защитить груз!",[11208]="Поставка для Драззита",[11209]="Сделка Ната",[11210]="Он настоящий!",
    [11211]="Помощь деревне Шестермуть",[11212]="Ферма Табеты",[11213]="Навестить Табету",
    [11214]="Миссия в Шестермуть",[11215]="Помощь Шестермути",[11216]="Верховный маг Альтур",
    [11217]="Тяни змею за хвост!",[11220]="Всадник без головы",[11221]="Донесения с полей",
    [11222]="Доказательство измены",[11223]="Возвращение к Джайне",[11224]="Пришли мулов сюда",
    [11225]="Отшельник с Ведьминого холма",[11227]="Пусть едят вволю!",[11228]="Во власти ледяного кошмара...",
    [11229]="Флагман \"Ветрокрылая\"",[11230]="В засаде!",[11231]="О ключах и клетках",[11232]="Дайте нам знак",
    [11233]="Решающий удар",[11234]="Доложите Ансельму",[11235]="Очистить Гьялерброн",[11236]="Некро-владыка Мезхен",
    [11237]="Гьялербронский план нападения",[11238]="Ледяной змей и его повелитель",[11239]="На службе Света",
    [11240]="Предводитель Спятивших",[11242]="Наконец, свободен!",[11243]="Если Валгард падет...",
    [11244]="На помощь спасателям",[11245]="Смертельно опасные башни",[11246]="Тяжело, но необходимо",
    [11247]="Гори, Скорн, гори!",[11248]="Операция: Атака на Скорн",[11249]="Остановить вознесение!",
    [11250]="Слава покорителю Скорна!",[11251]="С новыми силами",[11252]="На Утгард!",[11253]="По следу врага",
    [11254]="Карта на шкуре дракона",[11255]="Пленники в Деревне Драконьего Черепа",[11256]="Скорн должен пасть!",
    [11257]="Тяжело, но необходимо",[11258]="Гори, Скорн, гори!",[11259]="Смертельно опасные башни",
    [11260]="Остановить вознесение!",[11261]="Покоритель Скорна!",[11262]="Ингвар должен умереть!",
    [11263]="Очистить Гьялерброн",[11264]="Некро-владыка Мезхен",[11265]="О ключах и клетках",
    [11266]="Гьялербронский план нападения",[11267]="Ледяной змей и его повелитель",[11268]="Ходячие мертвецы",
    [11269]="Работаем до упора",[11270]="Ужасы войны",[11271]="Спешные приготовления",[11272]="Сведение счетов",
    [11273]="Объединение людей",[11274]="Зедд мертв, детка?",[11275]="Охотничий рог",[11276]="И их осталось двое...",
    [11277]="Глубины порока",[11278]="Возвращение в Валгард",[11279]="Зеленые и светящиеся",
    [11280]="Драконис гастритис",[11281]="Подражая зову природы",[11282]="Урок страха",
    [11283]="Кровавая бойня в Гибльхейме",[11284]="Соседство с йети",[11285]="Гори, Гибльхейм!",
    [11286]="Артефакты Стальных ворот",[11287]="Найти ведуна Странника Туманов",[11288]="Сияние света",
    [11289]="Ведомый честью",[11290]="Военные планы Укротителей драконов",[11291]="В Крепость Западной Стражи!",
    [11294]="Пивоварня Громоваров ищет зазывалу!",[11295]="В наступление!",[11296]="Пленники терзающих вдов",
    [11297]="Слежка за нарушителями границ",[11298]="Что они пьют?",[11299]="Круг Правосудия",
    [11300]="Поражение на ринге",[11301]="Мозги! Мозги!",[11302]="Загадочные ледяные нимфы",[11303]="Засада",
    [11304]="Новый Агамонд",[11305]="Идеальная формула",[11306]="Нагреть и перемешать",[11307]="Полевые испытания",
    [11308]="Пора заметать следы",[11309]="Запчасти для Дженни",[11310]="Внимание: требуется сборка",
    [11311]="Сопротивляясь стихиям",[11312]="Заиндевевшая поляна",[11313]="Духи льда",[11314]="Падшие сестры",
    [11315]="Дикие ветви",[11316]="Порождения Холмистой поляны",
    [11318]="А теперь гонки на баранах... Или вроде того.",[11321]="Кто сказал \"сувениры\"?",[11322]="Очищение",
    [11323]="В обличье ворга",[11324]="Альфа-ворг",[11325]="В обличье ворга",[11326]="Альфа-ворг",
    [11327]="Задание: найти сверток",[11328]="Задание: чума Отрекшихся",[11329]="Я готов на все!",
    [11330]="Это... точно сработает!",[11331]="Ик... Ты ему и скажи!",[11332]="Задание: уничтожить чуму!",
    [11333]="В мир духов",[11335]="Призыв к оружию: низина Арати",[11336]="Призыв к оружию: Альтеракская долина",
    [11337]="Призыв к оружию: Око Бури",[11338]="Призыв к оружию: ущелье Песни Войны",
    [11339]="Призыв к оружию: низина Арати",[11340]="Призыв к оружию: Альтеракская долина",
    [11341]="Призыв к оружию: Око Бури",[11342]="Призыв к оружию: ущелье Песни Войны",[11343]="Эхо Имирона",
    [11344]="Страдания Ниффлвара",[11346]="Книга Рун",[11348]="Руна подчинения",[11349]="Освоение рун",
    [11350]="Книга Рун",[11351]="Освоение рун",[11352]="Руна подчинения",
    [11354]="Разыскивается: Ездовой хлыстик Назана",[11357]="Попечительница сирот в маске",[11358]="Магнит",
    [11361]="Учения пожарной бригады",[11362]="Разыскивается: Украшенный перьями посох Кели'дана",
    [11363]="Разыскивается: печать Острорука",[11364]="Разыскиваются: Центурионы клана Изувеченной Длани",
    [11365]="Марш великанов",[11366]="Магнит",[11367]="Уничтожить Мегалита",
    [11368]="Разыскивается: сердце Квагмирран",[11369]="Разыскивается: яйцо Черной Охотницы",
    [11370]="Требуется: трактат полководца",[11371]="Разыскиваются: Мирмидоны Резервуара Кривого Клыка",
    [11372]="Разыскиваются: головные перья Айкисса",[11373]="Разыскивается: Заговоренный Амулет Шаффара",
    [11374]="Разыскивается: Самоцвет души Экзарха",[11375]="Разыскивается: Шепот Бормотуна",[11377]="Месть сладка",
    [11381]="Супчик для души",[11382]="Разыскиваются: песочные часы Эонуса",
    [11383]="Разыскиваются: Повелители временных разломов",[11384]="Разыскивается: Отросток Узлодревня",
    [11385]="Разыскиваются: Солнцеловы-чаротворцы",[11386]="Разыскивается: Проектор Паталеона",
    [11387]="Разыскиваются: разрушители из кузни бурь",[11388]="Разыскивается: Свиток Скайрисса",
    [11389]="Разыскиваются: Часовые Аркатраца",[11390]="У меня есть ветролет!",[11392]="Вызов Всадника без головы",
    [11393]="Куда пропал исследователь Джарен?",[11394]="Думаешь, мурлоки – самые вонючие существа?",
    [11395]="Устройство Плети",[11396]="Отключи защитное поле",[11397]="Думаешь, мурлоки – самые вонючие существа?",
    [11398]="Устройство Плети",[11401]="Вызов Всадника без головы",[11405]="Вызов Всадника без головы",
    [11409]="А теперь гонки на баранах... Или вроде того.",[11410]="Та самая рыбка",
    [11413]="Кто сказал \"сувениры\"?",[11414]="Братья-предатели",[11415]="Братья-предатели",[11416]="Глаза орлицы",
    [11417]="Глаза орлицы",[11419]="Скаковые бараны Хмельного фестиваля",[11420]="Путь к отмщению",
    [11421]="До упора...",[11422]="Трезубец сына",[11423]="Наследие врагов",[11424]="Заградительный холм",
    [11425]="Test Quest - Craig",[11426]="В поисках механизма",[11427]="Познакомьтесь с лейтенантом Ледяным Молотом",
    [11428]="Хранитель Листопад",[11429]="Защищай знамя до последнего!",[11431]="Поймать дикого зайцелопа!",
    [11432]="Спящие великаны",[11433]="Спящие великаны",[11434]="Забытое сокровище",
    [11442]="Добро пожаловать на Хмельной фестиваль!",[11447]="Добро пожаловать на Хмельной фестиваль!",
    [11450]="Учения пожарной бригады",[11451]="Стишок Алисии",[11452]="Спящий король",[11454]="Поиски диверсантов",
    [11455]="Запах денег",[11456]="Мясо для выживших",[11457]="Вооружая Камагуа",[11458]="Месть за Искаал",
    [11459]="Что сказал Зех'ген",[11460]="Завоевание доверия",[11461]="ИСКЛЮЧЕНО",[11464]="Карточный долг",
    [11465]="Разграбленный караван",[11466]="Стаканчик для Джека",[11467]="Долг мертвеца",
    [11468]="Ястреб против сокола",[11469]="Мыло для чистки палуб",[11470]="Птицы не знают о чести",
    [11471]="Конец игры",[11472]="Путь к его сердцу...",[11473]="Предатель среди нас",[11474]="Беда на Крутых утесах",
    [11475]="Орудия труда",[11476]="Нож и лягушка",[11477]="Дворф другой породы",[11478]="На той заставе...",
    [11479]="\"Хромой\" Дэн",[11480]="Познакомьтесь с номером два",
    [11481]="Чрезвычайная ситуация у Солнечного Колодца",[11482]="Зов долга",[11483]="Мы тоже так можем!",
    [11484]="Мы знаем технологию",[11485]="Голем Железной руны: обучение \"Реактивному прыжку\"",
    [11488]="Терраса Магистров",[11489]="Голем Железной руны: обучение \"Сбору информации\"",
    [11490]="Провидец Провидцев",[11491]="Голем Железной руны: обучение \"Обманке\"",[11492]="Страшный противник",
    [11494]="Заряженные молнией артефакты",[11495]="Нежный звук грома",[11496]="Охрана святилища",
    [11497]="Орлята учатся летать",[11498]="Орлята учатся летать",
    [11499]="Разыскивается: перстень-печатка принца Кель'таса",[11500]="Разыскиваются: сестры Терзаний",
    [11501]="Вести с востока",[11502]="Защита Халаа",[11503]="Враги старые и враги новые",[11504]="Ожившие мертвецы",
    [11505]="Духи Аукиндона",[11506]="Духи Аукиндона",[11507]="Старейшина Атуик из Камагуа",
    [11508]="Греззикс Иглохруст",[11509]="Чудак среди чудаков",[11510]="\"Челюсти\"",[11511]="Посох Неистовства Бури",
    [11512]="Ледяное сердце Исулдофа",[11513]="Перехват контейнеров с маной",
    [11514]="Поддержка портала Солнечного Колодца",[11515]="Кровь за кровь",[11516]="Взрыв врат",
    [11517]="Встреча с Назууном",[11519]="Пропавший щит Эсиритса",[11520]="Смотри в корень",
    [11521]="И опять – смотри в корень",[11523]="Подпитка для силового поля",[11524]="Хаотичное поведение",
    [11525]="Дальнейшая перенастройка",[11526]="Пропавший магистр",[11528]="Подарок к Зимнему Покрову",
    [11529]="Сокровища Сорлофа",[11531]="Странная деталь мотора",[11532]="Отвлекающий маневр на Тропе Мертвых",
    [11533]="Воздушные атаки должны продолжаться!",[11534]="Встреча с Назууном",[11535]="Подготовка к работе",
    [11536]="Продолжаем...",[11537]="Битва должна продолжаться!",[11538]="Сражение за оружейную Солнечного Края",
    [11539]="Захват гавани",[11540]="Клинки Рассвета должны быть сокрушены!",[11541]="Зачистить берег Зеленожабрых!",
    [11542]="Перехватить подкрепление",[11543]="Загнать врага в угол",[11544]="Оружие Ата'мала",
    [11545]="Никто не забыт...",[11546]="Взаимовыгодный бизнес",[11547]="Знай свою силовую линию!",
    [11548]="Щедрое пожертвование",[11549]="Великодушный благодетель",[11550]="Входи, Искуситель...",
    [11551]="[Agamath, the First Gate]",[11554]="Солдатская дружба",[11555]="Уважение союзников",
    [11556]="Почтение боевых друзей",[11558]="Опасная любовь",[11559]="Торговля с Зимними Плавниками",
    [11560]="О нет, наши бедные малыши!",[11561]="Они!",[11562]="Меня хотят очернить!",
    [11563]="Грммурглл Мрллглл Глрггл!",[11564]="Сочное жаркое из косатки",[11565]="Запасной комплект",
    [11566]="Сдаться? Ни за что!",[11567]="Древняя броня Квалдира",[11568]="Возвращение святынь",
    [11569]="Хранитель ключей Ургргрл",[11570]="Бегство из пещер Зимних Плавников",[11571]="Обучение коммуникации",
    [11572]="Возвращение к Атуику",[11573]="Орфус Камагуанский",[11574]="Переживания на грани",
    [11575]="Своевременное спасение",[11576]="Наблюдения за расселиной: обнаружена аномалия",
    [11578]="The \"Chow\" Quest (123)aa COPY",[11581]="Осквернение огня",[11584]="Поклонение огню",
    [11585]="Бдение Адского Крика",[11586]="Бдение Адского Крика",[11587]="Побег из тюрьмы",[11590]="Похищение",
    [11591]="Явиться в караван Стальной Челюсти",[11592]="Мы ударим!",[11593]="Последние почести",
    [11594]="Пусть обретут покой!",[11595]="Оборона крепости Песни Войны",[11596]="Оборона крепости Песни Войны",
    [11597]="Оборона крепости Песни Войны",[11598]="Отвоевывание карьера Камня Силы",[11599]="Тассариан, мой брат",
    [11600]="Последние новости о Вильяме Аллертоне",[11601]="Потерянный и обретенный",[11602]="Прервать на корню",
    [11603]="Истина в вине",[11604]="Дезертир",[11605]="Досточтимые предки",
    [11606]="Терпение – добродетель, которая не требуется",[11607]="Заблудшие духи",
    [11608]="Засыпать тараканьи норы!",[11609]="Сбор ритуальных предметов",[11610]="Возвращение предков",
    [11611]="Захваченные Плетью",[11612]="Бой за карьер",[11613]="Клятва Карука",[11614]="Невысказанные истины",
    [11615]="Неруб'арские тайны",[11616]="Послание Адскому Крику",[11617]="Никто не должен уйти",
    [11618]="Подкрепление на подходе…",[11619]="Геймел Жестокий",[11620]="Отцовские слова",
    [11621]="Табличка Левирота",[11622]="Тайны Терзающего Бича",[11623]="Визит к смотрителю",[11624]="Небо знает",
    [11625]="Трезубец Наз'жана",[11626]="Посланник",[11627]="Точка кипения",
    [11628]="Нечистое должно послужить чистому",[11629]="Назад, к говорящей с духами",
    [11630]="Оскверненная Плетью земля",[11631]="Воздушные видения",[11632]="Что несет холодный ветер?..",
    [11633]="Вписаться в ландшафт",[11634]="Повелитель ветра То'бор",[11635]="Дух предсказателя Печального Путника",
    [11636]="Полет на ковре-самолете",[11637]="Каганишу",[11638]="Вернуть мои останки",[11639]="Месть в Магмоте",
    [11640]="Слова могущества",[11641]="Смелость города берет!",[11642]="Танк сам собой не починится!",
    [11643]="Танковая пневматическая трансзажиматрица Мобу",[11644]="Сверхпрочные металлические пластины!",
    [11645]="Грязные, вонючие снобольды!",[11646]="Борейские дознаватели",[11647]="Обезвредить чумные котлы",
    [11648]="Искусство убеждения",[11649]="Частицы разгневанных бурь",[11650]="Еще кое-что…",
    [11651]="Броня крепка, и танки наши…",[11652]="Равнины Назама",[11653]="Ха! Не такой уж ты и большой теперь!",
    [11654]="Шпиль Крови",[11655]="В туман",[11657]="Поймай факел!",[11658]="План Б",[11659]="Уничтожьте шары!",
    [11660]="Рог старого морехода",[11661]="Орабус Кормчий",[11662]="Найти Карука",[11663]="Передача сведений",
    [11669]="Филе сквернокровного луциана",[11670]="Это были орки, честно!",[11671]="Наперегонки со временем",
    [11672]="День зачисления",[11673]="Вытащите меня отсюда!",[11674]="Ведунья Высокий Холм пропала!",
    [11675]="Достойная смерть",[11676]="Наконец-то свобода!",[11677]="Остановить чуму!",
    [11678]="Поиски Торчащего Рога",[11679]="Воссоздание ключа",[11680]="Полетаем?",[11681]="Спасение Эванор",
    [11682]="Беседа с драконом",[11683]="Упавший некрополь",[11684]="Исследование воронок",[11685]="Сердце стихий",
    [11686]="Фермы Песни Войны",[11687]="Доктор и Лич-Лорд",[11688]="Проклятые грязные свиньи",
    [11689]="Вестник печали",[11691]="Призовите Ахуна",[11692]="В поисках Бикси",
    [11693]="Только не чумной магнатавр!",[11694]="В пещерах что-то происходит...",[11696]="Ахун явился!",
    [11697]="Тинки в некрополе!",[11698]="Может, проще уничтожить Плеть?",
    [11699]="Я застряла в проклятой клетке… но ненадолго!",[11700]="Сообщение для Бикси",
    [11701]="Возвращение к взлетной полосе",[11702]="Король Мргл-Мргл",[11703]="Добраться до Гетри",
    [11704]="Король Мргл-Мргл",[11705]="Бесполезные старания",[11706]="Обрушение",[11707]="Просьба о помощи",
    [11708]="Мехагномы",[11709]="Поручение Нока Кровавое Бешенство",[11710]="Что такое с передачником?",
    [11711]="Доставка дезертиров: 30 минут, или вы не платите!",[11712]="Перепроклятие",
    [11713]="Исследование воронок",[11714]="Дератизация",[11715]="В поисках топлива",[11716]="Удивительный кровоспор",
    [11717]="Быстродействующая пыльца",[11718]="Автомат в мамонтовой шкуре",[11719]="Подопытное животное",
    [11720]="Вторжение в Гаммот",[11721]="Гаммотра Мучитель",[11722]="Трофеи из Гаммота",
    [11723]="Запустить Страх-и-ужас",[11724]="Для гигантского омлета?",[11725]="Поиски пилота \"Штопора\"",
    [11726]="Добавить специй по вкусу...",[11727]="Время героев",[11728]="Собаки-каки",
    [11729]="Ультразвуковая отвертка",[11732]="Осквернение огня",[11787]="Осквернение огня",[11788]="Смерть роботам!",
    [11789]="Солдат в беде",[11790]="Сектанты среди нас",[11791]="Сообщить Арлосу",[11792]="Враги света",
    [11793]="Дальнейшее расследование",[11794]="Охота началась!",
    [11795]="\"Действия в чрезвычайных ситуациях\": раздел 8.2, параграф 3",
    [11796]="\"Действия в чрезвычайных ситуациях\": раздел 8.2, параграф 4",[11797]="Осада",[11863]="Поклонение огню",
    [11864]="Вступление",[11865]="Им рано умирать",[11866]="Уши мертвых врагов",[11867]="Коллекция ушей",
    [11868]="Сортировщица грядет!",[11869]="Судьба моллюсков",[11870]="Покинутый предел",[11871]="Пока мы на страже",
    [11872]="Гнусный специалист по моллюскам",[11873]="Новости для Выкрутеня",[11875]="Обретение преимущества",
    [11876]="Помоги тем, кто не может помочь себе сам",[11877]="План нападения клана Ярости Солнца",
    [11878]="Ку'нок обо всем позаботится!",[11879]="Кау Гроза Мамонтов",[11880]="Мультифазовый подход",
    [11883]="Танцы с огнем?",[11884]="Нед, \"Повелитель люторогов\"",[11886]="Необычная активность",
    [11887]="Неприкосновенный запас",[11888]="Поездка в деревню Таунка'ле",[11889]="Смерть с небес",
    [11891]="Невинный маскарад",[11892]="Убить Гарольда Лейна!",[11893]="Сила стихий",[11894]="Заплатки",
    [11895]="Одолеть бурю",[11896]="Уязвимы для молний",[11897]="Заткнуть воронки!",[11898]="Прорыв",
    [11899]="Души распроклятых",[11900]="Что показывают приборы?",[11901]="Военные? Какие военные?",
    [11902]="Ужасное свидетельство",[11903]="Время действовать!",[11904]="Плоды трудов наших",
    [11905]="Оттянуть неотвратимое",[11906]="Очищение прудов",[11907]="Подручные Механозода",
    [11908]="Справочные материалы",[11909]="Убить механизатора!",[11910]="Тайны Древних",[11911]="Преображение",
    [11912]="На подножном корму",[11913]="Надо действовать наверняка",[11915]="Игра с огнем",[11917]="Ответный удар",
    [11918]="Первое знакомство",[11919]="Охота на драконов",[11926]="Опять бросаем факелы",
    [11927]="Встреча в трактире",[11928]="Далечье",[11929]="Гибель деревни Таунка'ле",[11930]="Через Трансборею",
    [11931]="Взломать шифр",[11935]="Похищение пламени Луносвета",[11936]="Наклевывается план!",
    [11938]="Отвлечь противника",[11939]="?????",[11940]="Охота на драконов",[11941]="Загадочный обломок",
    [11942]="Слова могущества",[11943]="Магическая клетка",[11944]="В окружении!",
    [11945]="Подготовка к самому худшему",[11948]="Ответный удар",[11949]="Не сдаваться без боя!",
    [11950]="Мудрость Муахита",[11955]="Ахун, Повелитель Холода",[11956]="Поиски талисмана",
    [11957]="Смерть Сарагосе!",[11958]="Чтоб ничего не пропало!",[11959]="Убить Логуна!",[11960]="Планы на будущее",
    [11961]="Духи присматривают за нами",[11962]="Последняя партия",[11964]="Благовония для летних пламеней",
    [11966]="Благовония для праздничных сполохов",[11967]="Сбор красных драконов",[11968]="Поворот колеса Фортуны",
    [11972]="Осколки Ахуна",[11976]="Ледяные осколки",[11977]="Таурен среди таунка",[11978]="Добро пожаловать в Орду",
    [11979]="Таунка и таурены",[11980]="Гордость Орды",[11981]="Найди Куруна!",[11982]="Каменный дождь",
    [11983]="Клятва крови Орды",[11984]="Захлопнуть клетку",[11985]="Битва в Проломе",[11986]="Потрепанный дневник",
    [11988]="Рунический краеугольный камень",[11989]="Перемирие?",[11990]="Пузырек видений",
    [11991]="Требуется расшифровка",[11993]="Рунические пророчества",
    [11995]="Безотлагательное путешествие в Покой Звезд",[11996]="Безотлагательное путешествие в Молот Агмара",
    [11997]="REUSE",[11998]="Подсластить пилюлю",[11999]="Обшарить трупы",[12000]="Обшарить трупы",
    [12002]="Братья по оружию",[12003]="В поисках туннелей",[12004]="Предотвратить союз",[12005]="Предотвратить союз",
    [12006]="Месть за бесчинства!",[12007]="Необходимые жертвы",[12008]="Молот Агмара",
    [12009]="Крабовые ловушки Туа'кеа",[12010]="Что случилось с Орлондом?",[12012]="Сообщи старейшинам",
    [12013]="Покончить с Арканимусом!",[12014]="Крепкий как камень?",[12015]="Тестовое задание для Крейга",
    [12016]="Наживка",[12017]="Наживка на крючке",[12020]="Однажды, напившись в...",[12022]="Пей до дна!",
    [12026]="Порванный журнал",[12027]="Удивительное приключение мистера Ушастика",[12028]="Духовное озарение",
    [12029]="Пылающая Плеть",[12030]="Старейшина Мана'лоа",[12031]="Свобода перемещения",[12032]="Разговор с бездной",
    [12033]="Послание с запада",[12034]="Победа близка…",[12035]="Переналадка технологии",
    [12036]="Глубины Азжол-Неруба",[12037]="Спасательная операция",[12038]="Пылающая Плеть",
    [12039]="Черная кровь Йогг-Сарона",[12040]="Общий враг в лице Артаса",[12041]="Потерянная империя",
    [12042]="Сердце древних",[12043]="Защита Лагеря Соплозабилось",[12044]="Припасти руды",[12045]="Битый лед",
    [12046]="Мягкая оболочка",[12047]="Нечто тугоплавкое",[12048]="Доспехи воинов Плети",[12049]="Мясо с пылу с жару",
    [12050]="Лесорубы",[12051]="Выдирание перьев",[12052]="Смерть гарпиям!",[12053]="Мощь Орды",
    [12054]="Расшифровать записи",[12055]="Странное приспособление",
    [12056]="Приговорен к смерти: верховный сектант Зангус",[12057]="Сшитый плотью фолиант",
    [12058]="Рунические пророчества",[12059]="Странное приспособление",[12060]="Проекты и проекции",
    [12062]="Оскорбить Корена Худовара",[12063]="Сила Ледяной Пыли",[12064]="Ануб'арские оковы",
    [12065]="Фокусы на взморье",[12066]="Фокусы на взморье",[12067]="Письмо домой",[12068]="Голоса прошлого",
    [12069]="Возвращение верховного вождя",[12070]="Второе дыхание",[12071]="Ударим с воздуха!",
    [12072]="Будь прокляты эти чумные звери!",[12073]="Куй железо, пока горячо",[12074]="Удобный союзник",
    [12075]="Образец каменной плоти",[12076]="Грязное дело",[12077]="Употреблять дважды в день",
    [12078]="Червячный наездник",[12079]="Излюбленное место червяков",[12080]="Вот это червяк!",[12081]="Гаврок",
    [12082]="Дун-да-Дун-та!",[12083]="В лесах",[12084]="В лесах",[12085]="Письмо домой",[12086]="Сын Каркута",
    [12087]="Немного помочь? DEPRECATED",[12088]="Тассариан, рыцарь Смерти",
    [12089]="Разыскивается: магистр Кельдонус!",[12090]="Разыскивается: Гигантавр",
    [12091]="Разыскивается: Коготь Ужаса",[12092]="Усиление древняков",[12093]="Руны порабощения",
    [12094]="Спящая сила",[12095]="В Драконью Погибель",[12096]="Усиление древняков",[12097]="Сарастра, бич Севера",
    [12098]="Поиски в деревне Инду'ле",[12099]="Долгожданная свобода",[12100]="Сдерживание гнили",
    [12101]="Добрый доктор...",[12102]="В поисках рубиновой сирени",[12104]="Вакцина для Соара",
    [12105]="Погружение во мрак",[12106]="Поиски в деревне Инду'ле",[12107]="Конец цепочки",[12108]="ИСКЛЮЧЕНО",
    [12109]="И снова к Гриану Камнегриву...",[12110]="Конец цепочки",[12111]="Где бродят дикие звери",
    [12112]="Деловые отношения",[12113]="Здравствуй, мяско!",[12114]="Анти-стрессовая терапия",
    [12115]="Кольтира и язык смерти",[12116]="Только смелым покоряются...",[12117]="Путешествие в гавань Моа'ки",
    [12118]="Путешествие в гавань Моа'ки",[12119]="Добиться аудиенции",[12120]="Молот Драк'агуула",
    [12121]="Увидимся в другом мире",[12122]="Добиться аудиенции",[12123]="Информация для королевы",
    [12124]="Информация для королевы",[12125]="Ради крови",[12126]="На службе нечестивости",
    [12127]="На службе у мороза",[12128]="Как дела у Регара?",[12129]="Безукоризненный замысел",
    [12130]="Зачем ковать то, что можно отобрать?",[12131]="Нам нужна энергия",[12133]="Разбей тыкву!",
    [12135]="\"И гори все огнем!\"",[12136]="Переведенная книга",[12137]="Остынь, чудо!",
    [12139]="\"И гори все огнем!\"",[12140]="Славься, Роанук!",[12141]="Дипломатическое поручение",
    [12142]="Контроль над чумой",[12143]="Преследование в каньоне",[12144]="Заразу – под контроль!",
    [12145]="Преследование в каньоне",[12146]="Зловещие выводы",[12147]="Зловещие выводы",
    [12148]="Единственный в своем роде",[12149]="Могучие магнатавры",[12150]="Мастер рун-затворник",
    [12151]="Распоясавшийся полководец",[12152]="Погибель Джин'аррака",[12153]="Тан и его Наковальня",
    [12155]="Разбей тыкву!",[12156]="DEPRECAED",[12157]="Пропавший курьер",[12158]="Рудник Полого Камня",
    [12159]="Неупокоенные души",[12160]="Имя из прошлого",[12161]="Рууна Слепая",[12162]="Деревня Солнцестояния",
    [12163]="The Evil Below",[12164]="Час ворга",[12165]="Коварный план",[12166]="Жидкое пламя Элуны",
    [12167]="Убить сектантов",[12168]="Памятный дар Зангуса",[12169]="Верховный сектант",
    [12170]="Схватка в Черноречье",[12173]="Настройка на Даларан",[12174]="Главнокомандующий Халфорд Змеевержец",
    [12175]="Серые шкуры воргов",[12176]="Мелкая подмена",[12177]="Уловка Джун'ика",[12179]="Specialization 1 [PH]",
    [12180]="Пленные геологи",[12181]="Имя для заразы",[12182]="В Ядозлобь!",[12183]="Часть маскировки",
    [12184]="Улыбайтесь, вас снимают!",[12185]="Лучшая маскировка для Локена",
    [12188]="Гниль Отрекшихся и вы: как не заразиться самим",[12189]="Меня окружают идиоты!",
    [12194]="А не будет ли сувенирчика в нынешнем году?",[12195]="Незваный гость",[12196]="С самого начала",
    [12197]="Нам нужна энергия",[12198]="... а может быть, и нет",[12199]="Свержение железного тана",
    [12200]="Слезы изумрудного дракона",[12201]="Тень надзирателя",[12202]="Улыбайтесь, вас снимают!",
    [12203]="Приказы Локена",[12204]="Во имя Локена",[12205]="Разыскивается: Алый Натиск",
    [12206]="Испорченные последние ритуалы",[12207]="Падение Фордрассила",[12208]="Удачи в охоте за троллями!",
    [12209]="Кража материальных ценностей",[12210]="Сезон охоты на троллей!",[12211]="Не дадим им подняться!",
    [12212]="Пополнение запасов",[12213]="Подземная тьма",[12214]="Новые кони",[12215]="Мы или они!",
    [12216]="Бери самое нежное!",[12217]="Орлиный взор",[12218]="Добрые вести не ждут на месте",
    [12219]="Обломки мирового древа",[12220]="Темное влияние",[12221]="Гниль Отрекшихся",
    [12222]="Тайны прядильщиц пламени",[12223]="Ослабление врага",[12224]="Авангард кор'крона",
    [12225]="М-м-м... Янтарные желуди!",[12226]="Ух, пронесло!",[12227]="За дело!",[12229]="Возможная связь",
    [12230]="Кража у осадных мастеров",[12231]="Отпрыски медвежьего бога",[12232]="Бомбардировка баллист",
    [12233]="[Depricated]Высадить семена",[12234]="Надо знать",[12235]="Наксрамас и падение крепости Стражей Зимы",
    [12236]="Урсок, медвежий бог",[12237]="Полет защитника Стражей Зимы",[12238]="Очищение Драк'Тарона",
    [12239]="Шпион в Новом Дольном Очаге",[12240]="Цель и средства",[12241]="Уничтожить саженец",
    [12242]="Семена Фордрассила",[12243]="Огонь над водами",[12244]="Починка крошшеров",
    [12245]="Никакой пощады пленникам",[12246]="Возможная связь",[12247]="Дети Урсока",[12248]="Саженец Фордрассила",
    [12249]="Урсок, медвежий бог",[12250]="Семена Фордрассила",[12251]="Возвращение к верховному главнокомандующему",
    [12252]="Истязание истязателя",[12253]="Спасение с городской площади",[12254]="Без молитвы – никак",
    [12255]="Тан Волдруна",[12256]="Тайны огневязов",[12257]="Демонстрация силы",[12258]="Судьба погибших",
    [12259]="Тан Волдруна",[12260]="Полное несходство",[12261]="Отрезать пути к отступлению",
    [12262]="Без надежды на спасение",[12263]="С наилучшими намерениями",[12264]="Разборка с Проклятыми",
    [12265]="Осквернение осквернителей",[12266]="Рассказ о разрушении",[12267]="Пламя Нелтариона",[12268]="Запчасти",
    [12269]="Только не c нашего рудника!",[12270]="Искрошить Альянс",[12271]="Жезл принуждения",
    [12272]="Кровоточащая руда",[12273]="Отречение",[12274]="Греховное падение",[12275]="Демогном",
    [12276]="В поисках Слинкина",[12278]="Клуб \"Пиво месяца\"",[12279]="Медвежий аппетит",[12280]="Текущий ремонт",
    [12281]="Понимание военной машины Плети",[12282]="Отпечатки былого",[12283]="Правду не скроешь",
    [12284]="Преследуй по пятам",[12286]="Кулек конфет",[12287]="Орик Чистосердечный и Забытое взморье",
    [12288]="В военном лазарете",[12289]="Нападем, пока враг слаб!",[12290]="Эликсир из темноплевела",
    [12291]="Забытая повесть",[12292]="Помощь местных жителей",[12293]="Дело сделано",[12294]="Заключение договора",
    [12295]="Урок дипломатии",[12296]="На грани жизни и смерти",[12297]="О предателях и предательстве",
    [12298]="Главнокомандующий Халфорд Змеевержец",[12299]="Северное гостеприимство",[12300]="Испытание смелости",
    [12301]="Правда вернет нам свободу",[12302]="Предупреждение",[12303]="Финансовое обеспечение военных нужд",
    [12304]="Недвижимость на взморье",[12306]="Клуб \"Пиво месяца\"",[12307]="Аконитовый корень",
    [12308]="Побег из Среброречья",[12309]="Найти Дюркона!",[12310]="Мгновенный ответ",
    [12311]="Подземная обитель некролорда",[12313]="Unused Save Brewfest!",[12314]="Смерть капитану Зорне!",
    [12315]="Смерть капитану Брайтвотеру!",[12316]="Припрем их к стенке!",[12318]="Спасем Хмельной фестиваль!",
    [12319]="Тайна книги",[12320]="Язык Смерти",[12321]="Праведная проповедь",[12323]="Выкурим их!",
    [12324]="Выкурим их!",[12325]="Заброс на вражескую территорию",[12326]="Паровой сюрприз",[12327]="Опыт вне тела",
    [12328]="Просьба Рууны",[12329]="Судьба и совпадения",[12371]="Кулек конфет",[12410]="Кулек конфет",
    [12411]="Спасение сестры",[12412]="Друг моего врага",[12413]="Нападение на Среброречье",
    [12414]="Лошадки для лагеря",[12415]="Пугалка для коней",[12416]="Горячая битва",[12417]="Погребение",
    [12418]="Через огненные поля",[12421]="Клуб \"Пиво месяца\"",[12422]="Расчетливая доброта",
    [12423]="Дневник Михаила",[12424]="Горгонна",[12425]="Рууна Слепая",[12426]="ИСКЛЮЧЕНО",
    [12427]="Бойцовская яма: медвежьи бои!",[12428]="Бойцовская яма: битва с бешеным фурболгом",
    [12429]="Бойцовская яма: кровь и железо",[12430]="Бойцовская яма: смерть близка",
    [12431]="Бойцовская яма: последняя битва",[12432]="Верхом на красной ракете",[12433]="В поисках растворителя",
    [12434]="Растворитель всегда пригодится!",[12435]="Явиться к лорду Деврестразу",[12436]="Прибавка к зарплате",
    [12437]="Верхом на красной ракете",[12438]="Разыскивается: Креуг Клятвопреступник",[12439]="Проблемы на западе",
    [12440]="В Покой Звезд!",[12441]="Разыскивается: верховный шаман Кровохват",
    [12442]="Разыскивается: командир Алого Натиска Иустус",[12443]="В поисках растворителя",
    [12444]="Резня в Черноречье",[12446]="Растворитель всегда пригодится!",[12447]="Обсидиановое святилище драконов",
    [12448]="Горячая битва",[12449]="Погребение",[12450]="Через огненные поля",[12451]="Вперед, в Лагерь Уанква",
    [12452]="zzOLD Судьба рубинового святилища драконов",[12453]="Взгляд с высоты",[12454]="Жизненный цикл",
    [12455]="Унесенные ветром",[12456]="Перо Алистоса",[12457]="Ты и пушка",[12458]="Семена плеточника",
    [12459]="Что создает, то может и разрушать",[12460]="Прибытие в Рубиновое святилище драконов",
    [12461]="Прибытие в Рубиновое святилище драконов",[12462]="Кирпичик за кирпичиком",
    [12463]="Жаднобород должен быть найден!",[12464]="Мой старый враг",[12465]="Дневник Жадноборода",
    [12466]="Погоня за Ледяной Бурей: передовая 7-го легиона",[12467]="Охота на Ледяную Бурю: филактерия Тель'зана",
    [12468]="Поручение Завоевательницы",[12469]="Вернуть отправителю",[12470]="Тайна бесконечности",
    [12471]="Жестокость квалдиров",[12472]="Шаг к победе",[12473]="Конец и начало",[12474]="За крепость Фордрагона!",
    [12475]="Какие тайны они скрывают?",[12476]="Возвращение Алого ордена?",[12477]="Путь искупления",
    [12478]="Пещера Ледяной Скорби",[12479]="Onwards to Northrend!",[12480]="Onwards to Northrend!",
    [12481]="Оскорбительное поражение",[12482]="Атака на Ниффлвар",[12483]="Похлебка из снежных грибов",
    [12484]="Шашлык из Плети",[12486]="Быстро, на заставу Бор'горока!",
    [12487]="В крепости Завоевателей держи ухо востро!",[12488]="Запрос от верховного палача",
    [12489]="Добро пожаловать в Низину Шолазар",[12492]="Худое варево Худовара",[12493]="Тест PvP",
    [12495]="Аудиенция у королевы драконов",[12496]="Аудиенция у королевы драконов",[12497]="Галакронд и армия Плети",
    [12498]="На рубиновых крыльях",[12499]="Возвращение в Ангратар",[12500]="Возвращение в Ангратар",
    [12501]="Тролльский дозор",[12502]="Тролльский дозор: выше знамена!",[12503]="Защита заставы",
    [12504]="Серебряный Авангард, уходим!",[12505]="Новый приказ для сержанта Метателя Молота",
    [12506]="Волнения у алтаря Шшератуса",[12507]="Странная настойка",[12508]="Зачистка территории",
    [12509]="Тролльский дозор: сила духа",[12510]="Совершенные элементальные флюиды",
    [12511]="У холмов есть не только глаза",[12512]="Спасти всех",[12513]="Милая шляпка...",[12514]="Грибная добавка",
    [12515]="Милая шляпка...",[12518]="Карты Новолуния: колода Магов",[12519]="Тролльский дозор: сбор медальонов",
    [12520]="Охота на люторогов: проверка",[12521]="Куда запропастился Хеминг Эрнестуэй?",
    [12522]="Нужен двигатель – найдем двигатель!",[12523]="Есть детали? – Тащи сюда!",
    [12524]="Проблемы Торговой Компании",[12525]="Сотри ухмылку с его лица",[12526]="Охота на люторогов: погоня",
    [12527]="Прожорливые твари",[12528]="Подыграть несложно",[12529]="Раб охотника на обезьян",
    [12530]="Вопли барабанчат",[12531]="Подземная угроза",[12532]="Побег из курятника",
    [12533]="Ученик охотника на ос",[12534]="Матка Сапфирового Улья",[12535]="Кристаллы силы",
    [12536]="Трудная поездка",[12537]="Молния все-таки бьет в то же место",[12538]="Шептуны не станут слушать",
    [12539]="Вместе весело шагать",[12540]="Исполнение приказа",[12541]="Тролльский дозор: в подмастерья к алхимику",
    [12542]="Зов Ордена",[12543]="Подношение Су-раму",[12544]="Скелет Нозронна",[12545]="Очищение Джинта'калара",
    [12546]="Отмщение",[12547]="Руна пробуждения",[12548]="Этимидиан",[12549]="Охота на терропардов: стать хищником",
    [12550]="Охота на терропардов: по следу зверя",[12551]="Охота на кроколисков: испытание",
    [12552]="Смерть некромагам!",[12553]="Прядильные органы",[12554]="Малас Осквернитель",[12555]="Оплетающие сети",
    [12556]="Охота на люторогов: смертельный удар",[12557]="Лабораторная работа",
    [12558]="Охота на терропардов: прыжок",[12559]="Включение Спирали: Обитель Творцов",
    [12560]="Охота на кроколисков: план",[12561]="Вопрос доверия",[12562]="Элементали не для Драккари",
    [12563]="Тролльский дозор",[12564]="Тролльский дозор: обезболивающее снадобье",[12565]="Благословение Зим'Абвы",
    [12566]="Помощь Лагерю Заиндевевшего Копыта",[12567]="Благословение Зим'Абвы",
    [12568]="Тролльский дозор: смертельная усталость",[12569]="Охота на кроколисков: засада",
    [12570]="Счастливое непонимание",[12571]="Большая Скверная Змея должна уйти",
    [12572]="Боги любят блестящие штучки",[12573]="Заключение мира",[12574]="Так скоро?",
    [12575]="Потерянное сокровище Шепота Тумана",[12576]="Тяжелая рука",[12577]="Пора домой!",
    [12578]="Разгневанный горлок",[12579]="Жизненная Сила для мохобродов",[12580]="Спаситель мохобродов",
    [12581]="Бремя героя",[12582]="Защитник племени Бешеного Сердца",[12583]="Разбившийся сеятель",
    [12584]="Зло в чистом виде",[12585]="Тролльский дозор: животворящее тепло",[12586]="В поисках крупной дичи",
    [12587]="Тролльский дозор",[12588]="Тролльский дозор: будем копать",[12589]="Ничего опасного",
    [12590]="Blahblah[PH]",[12591]="Тролльский дозор: подрывные работы",[12593]="На службе Короля-лича",
    [12594]="Тролльский дозор: зачистка местности",[12595]="В поисках крупной дичи",[12596]="Па'трулль",
    [12597]="Обезболивающее снадобье",[12598]="Подрывные работы",[12599]="Животворящее тепло",
    [12601]="В подмастерья к алхимику",[12602]="В подмастерья к алхимику",[12603]="Время точить когти",
    [12604]="Поздравляем!",[12605]="Подготовка ловушки",[12606]="В коконах",[12607]="Поимка мамонта",
    [12608]="Вторжение сектантов",[12609]="Пополнение запасов",[12610]="Подрезанные крылышки",
    [12611]="Семикратное воздаяние",[12612]="Разрушенная колонна",[12613]="Включение Спирали: Дозор Творцов",
    [12614]="Материнский гнев",[12615]="Благословение Зим'Торги",[12616]="Тайная комната",
    [12617]="Уничтожение захватчиков",[12619]="Украшенный рунический меч",[12620]="Гнев Хранительницы Жизни",
    [12621]="Договор Фрейи",[12622]="Вожди у Джин'Алаи",[12623]="К знахарю",[12625]="Власть над Акерусом",
    [12627]="Прорыв в Джин'Алаи",[12628]="Разговор с Хар'коа",[12629]="Можно убежать, но нельзя скрыться",
    [12630]="Насса надо как следует пнуть",[12631]="Приглашение",[12632]="Первым делом – мои дети",[12633]="Зов тьмы",
    [12634]="Кому ликер, кому лимонад",[12636]="Око Акеруса",[12637]="Счастливое избавление",
    [12638]="На волосок от смерти",[12639]="Застывшая земля",[12641]="Смерть подбирается с высоты",
    [12642]="Дух Рунока",[12643]="Серебряная отделка",[12644]="Выпивка – дело тонкое…",[12645]="Дегустация",
    [12646]="Пророк мой – враг мой",[12647]="Конец мучениям",[12648]="Маскировка",[12649]="Переодевание",
    [12650]="Разграбленное святилище",[12651]="Лагерь у озера",[12652]="Преющие вурдалаки проголодались",
    [12653]="Назад к Хар'коа",[12654]="Охотник на полставки",[12655]="Благословение Зим'Рука",[12657]="Мощь Плети",
    [12658]="Моя ручная птица Рух",[12659]="Скальпы!",[12660]="Орудия разрушения",[12661]="На разведку в Волтар",
    [12662]="Смерть Хеб'Джина",[12663]="Воссоединение",[12664]="Темный горизонт",[12665]="Дурное предчувствие",
    [12666]="Путешествие в Нижний мир",[12667]="Поиски богини крылатых змеев",[12668]="Задел для мести",
    [12670]="Жатва Алых",[12671]="Разведывательный полет",[12672]="Подготовка к мести",[12673]="Сбор кристаллов",
    [12674]="Вся ярость преисподней",[12675]="И последнее...",[12676]="Диверсия",[12680]="Великий угонщик",
    [12681]="Агент по реагентам",[12682]="Неразведанная территория (DEPRECATED)",[12683]="Жгучее желание помочь",
    [12684]="Кровь мертвого бога",[12685]="Что посеешь, то и пожнешь",[12687]="Путь в Долину Теней",
    [12688]="Проектирование аварии",[12689]="Длань Оракулов",[12690]="Нам это на руку",[12691]="Старинный сундук",
    [12692]="Возвращение охотника на личей",[12695]="Возвращение сухой шкуры",[12698]="Подарок с подвохом",
    [12701]="Побоище у Заставы Света",[12702]="И снова цыплята!",[12703]="Буйство Картака",
    [12704]="Умиротворение Великого камня дождя",[12706]="Победа у Разлома Смерти",[12707]="Яростное правосудие",
    [12708]="Заколдованные воины Тики",[12709]="Проклятые тайники",[12711]="Заброшенный почтовый ящик",
    [12712]="Ключ полководца Зол'Маза",[12720]="Как завоевывать друзей и оказывать влияние на врагов",
    [12725]="Братья по смерти",[12727]="Кровавый побег",[12728]="Наблюдения за расселиной: пещера Зимних Плавников",
    [12729]="Боги говорили с нами...",[12730]="Вызов в Зол'Хебе",[12733]="Вызов смерти",
    [12734]="Реджек: первая кровь",[12735]="Песнь Очищения",[12736]="Песнь Размышления",[12739]="Приятный сюрприз",
    [12740]="Парашюты для Серебряного Авангарда",[12757]="Теплый прием для армий Алого ордена",[12758]="Шлем героя",
    [12759]="Орудия войны",[12760]="Тайная сила племени Бешеного Сердца",[12761]="Власть над кристаллами",
    [12762]="Могущество Великих",[12763]="Смена приоритетов",[12766]="Разговор с послом",[12767]="Разговор с послом",
    [12768]="Распорядитель храма Драконьего Покоя",[12769]="Распорядитель храма Драконьего Покоя",
    [12779]="Конец всему...",[12780]="ИСПОРЧЕНО>>Враг наших врагов",[12788]="Луносвет",[12789]="В Разлом!",
    [12790]="Как уйти и вернуться: магический путь",[12791]="Магическое королевство Даларан",[12792]="Первым делом",
    [12793]="Дым на горизонте",[12794]="Магическое королевство Даларан",[12795]="На помощь заставе",
    [12796]="Магическое королевство Даларан",[12798]="Карты Новолуния: колода Мечей",[12801]="Сияние Рассвета",
    [12802]="Мое сердце – в твоих руках",[12803]="Сила природы",[12804]="Стейк, достойный охотника",
    [12805]="Сохранение жизненной силы",[12806]="На Уступ Смерти со всех ног!",[12809]="Стальгорн",
    [12812]="Оргриммар",[12813]="Из праха восстаньте!",[12814]="Потребность в грифоне",
    [12817]="Нападение Плети на Экзодар",[12818]="Сбор деталей",[12819]="Плевое дело",
    [12820]="Осторожное прикосновение",[12821]="Танго в тюремном блоке",[12822]="Средство для устрашения",
    [12823]="Безупречный план",[12824]="Выдающийся подрывник",[12825]="Выражение благодарности",
    [12826]="Почти безопасны",[12827]="Пополнение запасов провизии",[12828]="Полет вдохновения",
    [12829]="Перед тем, как входить",[12830]="Изъятие руды",[12831]="Ядовитый укус",[12832]="Побег",[12833]="Излишки",
    [12834]="Ни дождь, ни снег, ни катастрофа",[12835]="Все взрослые",[12836]="Выражение благодарности",
    [12837]="У Тор есть все, что надо",[12838]="Сбор информации",[12839]="Грандиозные планы верховного адмирала",
    [12840]="Совершенно секретно",[12842]="Ковка рун: подготовка к битве",[12843]="Они забрали наших мужчин!",
    [12844]="Вернуть оборудование",[12846]="Найти всех до единого...",[12850]="Командир сил Плети Таланор",
    [12851]="Медвежья хватка",[12852]="Поиски адмирала",[12853]="Поторопить события",[12854]="По следам Бранна",
    [12855]="Найти преступника",[12856]="Холодные сердца",[12857]="Плавник Ярогрива",[12858]="Кусочки головоломки",
    [12859]="Негасимый огонь",[12860]="Сбор информации",[12861]="Плохие тролли",
    [12862]="Когда остается единственный выход...",[12863]="Большое спасибо",[12864]="Пропавшие разведчики",
    [12865]="Верные друзья",[12866]="Сопротивление агрессорам",[12867]="Похитители птенцов",
    [12868]="Источник всех бед",[12869]="Все слишком далеко зашло",[12870]="Древние реликвии",
    [12871]="Помощь Лиги исследователей",[12872]="Оболочка Норганнона",[12873]="Король Зиморожденных",
    [12874]="Рвение Зиморожденного",[12875]="Опытный проводник",[12876]="Нежеланные гости",[12877]="Одинокий часовой",
    [12878]="Спрятанная реликвия",[12879]="Ярость короля Зиморожденных",[12880]="Главный исследователь",
    [12881]="Братья Бронзобороды",[12882]="Древние реликвии",[12883]="Приказы Дракуру",[12884]="Черная застава",
    [12885]="Изгнанники Ульдуара",[12886]="Драконобойца",[12887]="Непростая работа",[12888]="УБЕР-И",
    [12889]="Панель управления прототипом",[12890]="Если размер имеет значение...",[12891]="Воплощение идеи",
    [12892]="Непростая работа",[12893]="Освобождение разума",[12894]="Передовой лагерь рыцарей",
    [12895]="Пропавший Бронзобород",[12896]="Последний аргумент",[12897]="Последний аргумент",[12898]="Мрачный Свод",
    [12899]="Мрачный Свод",[12900]="Изготовление сбруи",[12901]="Что-то из ничего",[12902]="Кто за этим стоит?",
    [12903]="Для того и нужны друзья...",[12904]="Орудие мести",[12905]="Милдред Жестокая",
    [12906]="Поучить уму-разуму",[12907]="Нужны показательные примеры",[12908]="Наглая пленница",[12909]="Острый нюх",
    [12910]="Найти преступника",[12911]="Kill Credit Test",[12912]="Приближение великой бури",
    [12913]="Говори по-орочьи!",[12914]="Спасение Гимера",[12915]="Возобновление старых связей",
    [12916]="Наша единственная надежда",[12918]="Огранка камней",[12919]="Месть короля Бурь",
    [12920]="Вдогонку за Бранном",[12921]="Смена декораций",[12922]="Очищающее пламя",[12924]="Возобновление союза",
    [12925]="Верность традициям",[12926]="Кусочки головоломки",[12927]="Сбор информации",
    [12928]="Оболочка Норганнона",[12929]="Земельники Ульдуара",[12930]="Редкоземельный элемент",[12931]="Контратака",
    [12932]="Амфитеатр Страданий: Иггдрас!",[12933]="Амфитеатр Страданий: магнатавр!",
    [12934]="Амфитеатр Страданий: существо из другого мира!",[12935]="Амфитеатр Страданий: Клыкаррмагеддон!",
    [12936]="Амфитеатр Страданий: Коррак Кровопуск!",[12937]="Исцеление раненых",[12938]="Герцог",
    [12941]="Кулек конфет",[12942]="Черные крылья",[12947]="Кулек конфет",[12948]="Чемпион Амфитеатра Страданий",
    [12950]="Кулек конфет",[12952]="Огранка камней",[12953]="Гори, Валькирион, гори",
    [12954]="Амфитеатр Страданий: Иггдрас!",[12955]="Унижение соперников",[12956]="Лучик надежды",
    [12963]="Заказ от торговой компании: реликвия Восходящего Солнца",[12964]="Темная руда",[12965]="Дары Локена",
    [12966]="Мимо него не пройдешь",[12967]="Сражение со стихиями",[12968]="Безрассудство Юльды",
    [12969]="Это твой гоблин?",[12970]="Круг хильд",[12971]="Вызов принят",[12972]="Тебе понадобится медведь",
    [12973]="Братья Бронзобороды",[12974]="Призыв бойцовского клуба",[12975]="Мемориал",[12976]="Памятник павшим",
    [12977]="Зов Ходира",[12978]="Навстречу буре",[12979]="Доспехи тьмы",[12980]="Секрет доспехов",
    [12981]="Жар и холод",[12982]="Пленники из ордена Черного Клинка",[12983]="Последняя из рода",
    [12984]="Валдуран Дитя Бури",[12985]="Ковка шлема",[12986]="Судьба титанов",[12987]="Шлем Ходира",
    [12988]="Штормовые кузни",[12990]="Червоточина",[12991]="Удар по больному месту",[12992]="Истребление врайкулов",
    [12993]="Колоссальная опасность",[12994]="Контрразведчик",[12995]="Наша метка",[12996]="Тренировочный заезд",
    [12997]="В Яму!",[12998]="Сердце бури",[12999]="Костяная ведьма",[13000]="Чрезвычайные меры",
    [13002]="Огранка камней",[13004]="Огранка камней",[13005]="Клятва детей земли",[13006]="Полировка кислотой",
    [13007]="Железный колосс",[13008]="Тактика Плети",[13009]="Новое начало",[13010]="Кролмир, Молот Бурь",
    [13033]="Предок Арп",[13034]="Наблюдатель и герой",[13035]="Прислужники Локена",[13036]="Великая миссия",
    [13037]="Воспоминания о Штормовом Копыте",[13038]="Искажения времени",[13039]="Оборона аванпоста",
    [13041]="Недостающий камень",[13042]="В недрах Глубинных чертогов",[13043]="Когда сумма больше слагаемых",
    [13044]="Пропавшие без вести",[13045]="В чащобу",[13046]="Муки Арнгрима",[13047]="Свидетель",
    [13048]="Откуда время пошло не туда",[13049]="Доспехи героя",[13050]="Веранус",[13051]="Нарушение границ",
    [13052]="Воздушная разведка",[13053]="В поисках уцелевших",[13054]="Пропавший следопыт",
    [13055]="Лекарство из пещер",[13056]="Всегда найдется время для мести",[13057]="Терраса Творцов",
    [13058]="Чтобы ветер переменился",[13059]="Месть за варгулов",[13060]="Когда остается единственный выход...",
    [13061]="Победа или смерть",[13062]="Прощальный подарок Лок'лиры",[13063]="Посмотрим, чего ты стоишь",
    [13067]="Предок Чоган'гада",[13068]="Отважный герой",[13069]="Пристрели их",
    [13070]="Приближение холодного фронта",[13071]="Злоб любит огонь!",[13072]="Горькая участь героя",
    [13073]="Благосклонность хранителя",[13074]="Изумрудный кошмар",[13075]="Дар Ремула",[13076]="Время еще есть",
    [13077]="Прикосновение Аспекта",[13078]="Слезы Далии",[13079]="Дар Алекстразы",[13080]="Надежда жива",
    [13081]="Завещание наару",[13082]="Дар А'дала",[13083]="Свет во тьме",[13084]="Психологическая атака",
    [13085]="Возвращение Вэлена",[13090]="Кулинария севера",[13091]="Нелегко быть водным ужасом",
    [13092]="Гадание по костям",[13093]="Гадание по костям",[13094]="Ни стыда, ни совести",
    [13095]="Ни стыда, ни совести",[13096]="Гал'дара заплатит за все",[13097]="Неоконченное дело",
    [13098]="Для наших потомков",[13103]="Сыр для Златоплава",[13104]="И снова в Пролом",[13105]="И снова в Пролом",
    [13107]="Сосиски с горчицей!",[13108]="Любой ценой!",[13109]="Диаметральные противоположности",
    [13110]="Неупокоенные",[13116]="Сосиски с горчицей!",[13117]="Откуда они берутся?",[13118]="Очищение Плетхольма",
    [13119]="Разрушение алтарей",[13120]="Взгляд смерти",[13121]="Чужими глазами",[13122]="Камень Плети",
    [13124]="И вновь продолжается бой",[13125]="Чистое небо",[13126]="Единым фронтом",[13127]="Маг-лорд Уром",
    [13128]="Высокие ставки",[13129]="Игры разума",[13130]="Первый камень",[13131]="Пустой сундук",[13132]="Отмщение",
    [13133]="Поиски древнего героя",[13134]="Пролитая кровь",[13135]="Кристаллы энергии",
    [13136]="Зазубренные осколки",[13137]="Не совсем честный бой",[13138]="Непонятный металл",
    [13139]="Ледяное сердце Нордскола",[13140]="Руноковы Маликрисса",[13141]="Битва за Вершину Рыцарей",
    [13142]="Месть банши",[13143]="Новобранец",[13144]="Одним скелетом – двух воинов Плети!",
    [13145]="Зловещая крепость",[13146]="Предсказуемые и тупые",[13148]="Починка ожерелья",
    [13150]="zzOLDПотерянное устройство",[13151]="Королевский эскорт",[13152]="Визит к доктору",
    [13153]="Охрана для воинов",[13154]="Кости и стрелы",[13155]="Верет Хитрый",[13156]="Редкое растение",
    [13157]="Вершина Рыцарей",[13158]="Главное – скрытность",[13159]="Сдерживание",[13160]="Сногсшибательное зрелище",
    [13161]="Всадник Нечестивости",[13162]="Всадник Льда",[13163]="Всадник Крови",[13166]="Битва за Черный оплот",
    [13167]="Смерть королю-предателю!",[13168]="Простой урок",[13169]="Лучший друг нежити",
    [13170]="Честь – удел слабых",[13171]="Откуда придет удар",[13173]="Под шумок",[13174]="Под шумок",
    [13175]="Восстановление контроля",[13176]="Подготовка к доставке",[13177]="Беспощадным пощады не будет",
    [13178]="Убить всех и каждого!",[13179]="Беспощадным пощады не будет",[13180]="Убить всех и каждого!",
    [13181]="Победа на Озере Ледяных Оков",[13182]="И не забудь про яйца!",[13183]="Победа на Озере Ледяных Оков",
    [13184]="Больше нет нужды",[13185]="Остановка осады",[13186]="Остановка осады",[13189]="Благословение вождя",
    [13190]="Все хорошо в свое время",[13191]="Горючее для разрушителей",[13192]="Охрана стен",
    [13193]="Кости и стрелы",[13194]="Целительные розы",[13195]="Редкое растение",[13196]="Кости и стрелы",
    [13197]="Горючее для разрушителей",[13198]="Охрана для воинов",[13199]="Кости и стрелы",
    [13200]="Горючее для разрушителей",[13201]="Целительные розы",[13203]="Подарок к Зимнему Покрову",
    [13204]="Странные грибочки",[13205]="Разоружение",[13206]="Разоружение",[13207]="Чертоги Камня",
    [13211]="Сила очищающего огня",[13212]="Части тела",[13213]="Битва при Валхаласе",
    [13214]="Битва при Валхаласе: павшие герои",[13215]="Битва при Валхаласе: Кит'рикс Темный Повелитель",
    [13216]="Битва при Валхаласе: возвращение Сигрид Дитя Льда",[13217]="Битва при Валхаласе: Резчик-по-живому!",
    [13218]="Битва при Валхаласе: тан Смертельный Удар",[13219]="Битва при Валхаласе: последний бой",
    [13220]="Воскрешение Олакина",[13221]="Я еще жив!",[13222]="Защита осадных машин",[13223]="Защита осадных машин",
    [13224]="Молот Оргрима",[13225]="Усмиритель небес",[13226]="И пришел Судный День!",
    [13227]="И пришел Судный День!",[13228]="Прорванный фронт",[13229]="Я еще жив!",[13230]="Отомсти за меня!",
    [13231]="Прорванный фронт",[13232]="Прикончи меня!",[13233]="Пощады не будет!",[13234]="Они заплатят!",
    [13235]="Победитель мясистого великана",[13236]="Войско проклятых",[13237]="Тычки и тумаки",
    [13238]="Какая-то полезная штука",[13239]="Непостоянство",
    [13240]="Времиар превидит встречу с центрифужными созданиями!",
    [13241]="Времиар превидит встречу имирьярскими берсерками!",[13242]="Шевеление Тьмы",
    [13243]="Времиар превидит встречу с посланницами из рода Бесконечности!",
    [13244]="Времиар превидит встречу с титановыми воинами!",[13245]="Доказательство смерти: Ингвар Расхититель",
    [13246]="Доказательство смерти: Керистраза",[13247]="Доказательство смерти: хранитель энергии Эрегос",
    [13248]="Доказательство смерти: король Имирон",[13249]="Доказательство смерти: пророк Тарон'джа",
    [13250]="Доказательство смерти: Гал'дара",[13251]="Доказательство смерти: Мал'Ганис",
    [13252]="Доказательство смерти: Сьоннир Литейщик",[13253]="Доказательство смерти: Локен",
    [13254]="Доказательство смерти: Ануб'арак",[13255]="Доказательство смерти: глашатай Волаж",
    [13256]="Доказательство смерти: Синигоса",[13257]="Глашатай войны",[13258]="Замечательная возможность",
    [13259]="Закрепить преимущество",[13260]="Уж кто бы говорил!",[13261]="Непостоянство",[13262]="Мощный взрыв",
    [13263]="Фитиль короток!",[13265]="Сбор ткани",[13266]="Жизнь без сожалений",[13270]="Сбор ткани",
    [13272]="Сбор ткани",[13273]="В поисках ядра",[13274]="Хранитель ядра",[13275]="Пора прятаться!",
    [13276]="Как все погано!",[13277]="Борьба с великанами",[13278]="Корпой Оскверненный",[13279]="Основы химии",
    [13280]="Царь горы",[13281]="Избавление от чумы",[13282]="Возвращение на поверхность",[13283]="Царь горы",
    [13284]="Атака пехоты",[13285]="Изготовление краеугольного камня",[13286]="Хоть какая-нибудь помощь!",
    [13287]="Тычки и тумаки",[13288]="Как все погано!",[13289]="Как все погано!",[13290]="Немного внимания",
    [13291]="Заимствованная технология",[13292]="Решение проблемы",[13293]="В Имирхейм!",
    [13294]="Борьба с великанами",[13295]="Основы химии",[13296]="В Имирхейм!",[13297]="Избавление от чумы",
    [13299]="zzOLDПлащ огонька",[13300]="Рабы саронитовых шахт",[13301]="Атака пехоты",
    [13302]="Рабы саронитовых шахт",[13304]="Ремонт в полевых условиях",[13305]="Все к худшему",
    [13306]="Строим баррикады!",[13307]="Окровавленные знамена",[13308]="Игры разума",[13309]="Воздушный десант",
    [13311]="Карты Новолуния: колода Демонов",[13312]="Железный вал",[13313]="Ослепить соглядатаев!",
    [13314]="Перехватить донесения",[13315]="Предварительная разведка",[13316]="Стражи Корп'ретара",[13317]="----",
    [13318]="Перетащить и опустить",[13319]="Вершина иерархии",[13320]="Невоспроизводимый компонент",
    [13321]="Все переиграть",[13322]="Все переиграть",[13327]="Колода карт Новолуния: Нежить",[13328]="Вдребезги",
    [13329]="Пред Вратами Ужаса",[13330]="Кровь избранных",[13331]="Ослепление Альянса",[13332]="Строим баррикады!",
    [13333]="Перехват донесений",[13334]="Окровавленные знамена",[13335]="Пред Вратами Ужаса",
    [13336]="Кровь избранных",[13337]="Железный вал",[13338]="Стражи Корп'ретара",[13339]="Вдребезги",
    [13340]="Помощь в нападении",[13341]="Помощь в нападении",[13342]="Ненастоящий шпион",
    [13343]="Тайна бесконечности, мания преследования",[13344]="Ненастоящий шпион",[13345]="Слишком мало сведений",
    [13346]="Пусть злодеи не ведают покоя",[13347]="Восставший из праха",[13348]="Тщета",
    [13349]="Колыбель ледяных драконов",[13350]="Пусть злодеи не ведают покоя",[13351]="Предварительная разведка",
    [13352]="Перетащить и опустить",[13353]="Перетащить и опустить",[13354]="Вершина иерархии",
    [13355]="Невоспроизводимый компонент",[13356]="Все переиграть",[13357]="Все переиграть",
    [13358]="Ненастоящий шпион",[13359]="Место гибели драконов",[13360]="Время ответов",[13361]="Охотник и принц",
    [13362]="Знание – тяжкая ноша",[13363]="Помощь Серебряного Авангарда",[13364]="Гамбит Тириона",
    [13365]="Ненастоящий шпион",[13366]="Слишком мало сведений",[13367]="Пусть злодеи не ведают покоя",
    [13368]="Пусть злодеи не ведают покоя",[13369]="Против воли рока",[13370]="Королевский ход",
    [13371]="В ожидании дальнейших распоряжений",[13372]="Ключ к Радужному Средоточию",
    [13373]="Последнее слово техники",[13374]="Боевое задание",
    [13375]="Ключ к Радужному Средоточию (героический режим)",[13376]="Война продолжается",
    [13377]="Битва за Подгород",[13378]="Главный инженер Меднопал",[13379]="Зеленые технологии",
    [13380]="Возглавить нападение",[13381]="Боевой вылет",[13382]="Килотонны смерти",[13383]="Киллогерц",
    [13384]="Правосудие в Оке Вечности",[13385]="Героическое правосудие в Оке Вечности",[13386]="Разведка провала",
    [13387]="Круговая оборона",[13388]="Поджигай!",[13389]="Фитиль короток!",[13390]="Голос во тьме",
    [13391]="Пора прятаться!",[13392]="Возвращение на поверхность",[13393]="Ремонт в полевых условиях",
    [13394]="Все к худшему",[13395]="Войско проклятых",[13396]="Тщета",[13397]="Каньон Гибели Синдрагосы",
    [13398]="Место гибели драконов",[13399]="Время ответов",[13400]="Охотник и принц",[13401]="Знание – тяжкая ноша",
    [13402]="Помощь Тириона",[13403]="Гамбит Тириона",[13404]="Войска статического разряда: Зона бомбардировки",
    [13405]="К оружию! Берег Древних",[13406]="Новое излучение. Зона бомбардировки",[13407]="К оружию! Берег Древних",
    [13408]="Штурмовые укрепления",[13409]="Штурмовые укрепления",[13410]="Штурмовые укрепления",
    [13411]="Штурмовые укрепления",[13412]="Корастраза",[13413]="Асы, ввысь!",[13414]="Асы, ввысь!",
    [13415]="Пульт в библиотеке",[13416]="Пульт в библиотеке",[13417]="Братья Бронзобороды",
    [13418]="Подготовка к войне",[13419]="Подготовка к войне",[13420]="Вечный лед",[13421]="Больше Вечного льда!",
    [13422]="Поучить уму-разуму",[13423]="Подтверждение победы",[13424]="Обратно в Яму Клыка",
    [13425]="Смерть гнусным тварям!",[13426]="Ксанатавр, Свидетель",[13427]="К оружию! Альтеракская долина",
    [13428]="К оружию! Альтеракская долина",[13429]="Отвлекающий маневр",[13430]="Испытание наару: Магтеридон",
    [13431]="Дубина Кардеша",[13480]="Большая охота за яйцами",[13481]="Валим отсюда!",
    [13503]="Что вам надо? Шоколада!",[13524]="Побег из Среброречья",[13538]="Южный саботаж",[13548]="Кулек конфет",
    [13549]="Хвост трубой",[13556]="Яйца для Дубра'джина",[13603]="Клинок, достойный чемпиона",
    [13604]="Диск доступа к Архиву",[13606]="Печать Фрейи",[13607]="Священный планетарий",[13609]="Печать Ходира",
    [13610]="Печать Торима",[13611]="Печать Мимирона",[13616]="Клинок Зимы",[13627]="Откуда дровишки?",
    [13629]="Вал'анир, молот древних королей",[13654]="Странный оруженосец",[13814]="На равных с чемпионами",
    [13816]="Священный планетарий (героич.)",[13817]="Диск доступа к Архиву (героич.)",[13818]="Алгалон (героич.)",
    [13820]="Семья Рвизасовов",[13821]="Печать Фрейи (героич.)",[13822]="Печать Ходира (героич.)",
    [13823]="Печать Торима (героич.)",[13839]="Мастер стремительной атаки",[13843]="[The Scrapbot Construction Kit]",
    [13847]="У вражеских врат",[13864]="Битва у Цитадели",[13887]="Яйца ядошкурого равазавра",
    [13889]="Бедный, голодный равазаврик",[13903]="Обед из улья Гориши",[13904]="Всмятку, в мешочек или сырые?",
    [13905]="Перья опаляющего руха",[13906]="Они так быстро растут",[13908]="Приготовьтесь к поездке",
    [13914]="Перья опаляющего руха",[13915]="Бедный, голодный равазаврик",[13916]="Всмятку, в мешочек или сырые?",
    [13966]="Подарок Зимнего Покрова",[13986]="Раненый товарищ",[14030]="Голодающие Дарнаса",
    [14077]="Милосердие Света",[14080]="Остановить нападение",[14081]="Уроки верховой езды в Лесах Вечной Песни",
    [14082]="Уроки верховой езды в Экзодаре",[14083]="Уроки верховой езды в Дун Мороге",
    [14084]="Уроки верховой езды в Дун Мороге",[14085]="Уроки верховой езды в Дарнасе",
    [14086]="Уроки верховой езды в Оргриммаре",[14087]="Уроки верховой езды в Мулгоре",
    [14088]="Уроки верховой езды в Дуротаре",[14105]="Вестник смерти Карос",[14160]="Список заслуг",
    [14163]="К оружию! Остров Завоеваний",[14177]="Благодарный покойник",[14178]="К оружию! Низина Арати",
    [14179]="К оружию! Око Бури",[14180]="К оружию! Ущелье Песни Войны",[14181]="К оружию! Низина Арати",
    [14182]="К оружию! Око Бури",[14183]="К оружию! Ущелье Песни Войны",
    [14199]="Доказательство смерти: Черный рыцарь",[14203]="Промокший рецепт",[14349]="Приказ по армии",
    [14350]="Курьер из Багрового Легиона",[14351]="Битва за Хилсбрад",[14352]="Нечестивый союз",
    [14353]="Нечестивый союз",[14355]="В монастырь Алого ордена",[14356]="Силы разрушения...",[14421]="Cтражи смерти",
    [14436]="Дворфийские делишки",[14437]="Обряды Матери-Земли",[14438]="Недобрые соседи",
    [14439]="Путешествие в Громовой Утес",[14441]="Автограф Гарроша",[14443]="Потертая рукоять",
    [14444]="То, что знают драконы",[14488]="Получите, распишитесь",[20438]="Подходящая маскировка",
    [20439]="Встреча с магистром Хаторелем",[24216]="К оружию! Ущелье Песни Войны",
    [24217]="К оружию! Ущелье Песни Войны",[24218]="К оружию! Ущелье Песни Войны",
    [24219]="К оружию! Ущелье Песни Войны",[24220]="К оружию! Низина Арати",[24221]="К оружию! Низина Арати",
    [24223]="К оружию! Низина Арати",[24224]="К оружию! Ущелье Песни Войны",[24225]="К оружию! Ущелье Песни Войны",
    [24226]="К оружию! Низина Арати",[24426]="К оружию! Альтеракская долина",[24427]="К оружию! Альтеракская долина",
    [24428]="Странное стечение обстоятельств",[24429]="Странное стечение обстоятельств",
    [24442]="Планы нападения квалдиров",[24451]="Встреча с чародеем",[24454]="Возвращение к Каладису Сияющему Копью.",
    [24461]="Перековать меч",[24476]="Закалить клинок",[24480]="Залы Отражений",[24498]="Путь в Цитадель",
    [24499]="Тени замученных душ",[24500]="Гнев Короля-лича",[24506]="В ледяную цитадель",[24507]="Путь в Цитадель",
    [24508]="[Temp Quest Record]",[24509]="[Temp Quest Record]",[24510]="В ледяную цитадель",
    [24511]="Тени замученных душ",[24522]="Путешествие к Солнечному Колодцу",[24541]="Позаимствовать духи",
    [24545]="Святость и скверна",[24547]="Пиршество душ",[24548]="Расколотый трон",[24549]="Темная Скорбь...",
    [24553]="Очищение Кель'Делара",[24554]="Потертая рукоять",[24555]="То, что знают драконы",
    [24556]="Подходящая маскировка",[24557]="Планы Серебряного союза",[24558]="Возвращение к Миралию Блеску Солнца",
    [24559]="Перековать меч",[24560]="Закалить клинок",[24561]="Залы Отражений",
    [24562]="Путешествие к Солнечному Колодцу",[24563]="Талориен Искатель Рассвета",[24576]="Разговор по душам...",
    [24579]="Сартарион должен умереть!",[24580]="Ануб'Рекан должен умереть!",[24581]="Нот Чумной должен умереть!",
    [24582]="Инструктор Разувий должен умереть!",[24583]="Лоскутик должен умереть!",[24584]="Малигос должен умереть!",
    [24585]="Огненный Левиафан должен умереть!",[24586]="Острокрылая должна умереть!",
    [24587]="Повелитель горнов Игнис должен умереть!",[24588]="Разрушитель XT-002 должен умереть!",
    [24589]="Лорд Джараксус должен умереть!",[24590]="Лорд Ребрад должен умереть!",[24594]="Очищение Кель'Делара",
    [24595]="Очищение Кель'Делара",[24597]="Дар королю Штормграда",[24666]="Конец Королевской компании",
    [24682]="Яма Сарона",[24683]="Яма Сарона",[24710]="Зачистка Ямы",[24711]="Ледяная Скорбь",
    [24712]="[Deliverance from the Pit]",[24713]="[Frostmourne]",
    [24745]="Не любовь витает в воздухе (а что-то иное!)",[24748]="[The Lich King's Last Stand]",
    [24749]="Сила нечестивости",[24756]="Сила крови",[24793]="Засланный шпион",[24795]="Победа Серебряного союза",
    [24796]="Победа Серебряного союза",[24798]="Победа Похитителей Солнца",[24799]="Победа Похитителей Солнца",
    [24800]="Победа Похитителей Солнца",[24801]="Победа Похитителей Солнца",
    [24806]="Пусть тебе улыбнется удача – в другой раз!",[24815]="Выбери свой путь",[24819]="Перемены в душе",
    [24820]="Перемены в душе",[24821]="Перемены в душе",[24822]="Перемены в душе",[24823]="Путь разрушения",
    [24825]="Путь мудрости",[24826]="Путь мести",[24827]="Путь отваги",[24828]="Путь разрушения",
    [24829]="Путь разрушения",[24830]="Путь мудрости",[24831]="Путь мудрости",[24832]="Путь мести",
    [24833]="Путь мести",[24834]="Путь отваги",[24835]="Путь отваги",[24836]="Перемены в душе",
    [24837]="Перемены в душе",[24838]="Перемены в душе",[24839]="Перемены в душе",[24840]="Перемены в душе",
    [24841]="Перемены в душе",[24842]="Перемены в душе",[24843]="Перемены в душе",[24844]="Перемены в душе",
    [24845]="Перемены в душе",[24846]="Перемены в душе",[24851]="По горячим следам",
    [24857]="Нападение на Лагерь Нараче",[24869]="Перевербовка",[24870]="Оборона Черепного вала",
    [24871]="Оборона Черепного вала",[24872]="[Respite for a Tormented Soul]",[24873]="Болезненная задача",
    [24874]="Каждая капля крови...",[24875]="[Deprogramming]",[24876]="Оборона Черепного вала",
    [24877]="Оборона Черепного вала",[24878]="Болезненная задача",[24879]="Каждая капля крови...",
    [24896]="Classic Random 65-70 (Nth)",[24912]="Великая сила",[24914]="Личное имущество",
    [24915]="Воссоединение Могрейна",[24916]="Медальон Джайны",[24917]="Плач Мурадина",[24918]="Возмездие Сильваны",
    [24923]="Burning Crusade Random Heroic (Nth)",[25199]="Начальная подготовка",[25212]="Разведать обстановку",
    [25229]="Несколько хороших гномов",[25239]="Путь силы",[25240]="Путь силы",[25242]="Путь силы",
    [25246]="Перемены в душе",[25247]="Перемены в душе",[25248]="Перемены в душе",[25249]="Перемены в душе",
    [25283]="Готовим речь",[25285]="Входит и выходит!",[25286]="Слова, что нужно произнести",
    [25287]="Слова, что нужно произнести",[25289]="Шаг вперед...",[25295]="Шквальный огонь",
    [25306]="Теперь ты в армии, гном!",[25393]="Операция \"Гномреган\"",[25444]="Идеальные шпионы",
    [25445]="Падение Залазана",[25446]="Лягушачий десант",[25461]="Вербовочный троллинг",
    [25470]="Повелительница тигров",[25485]="World Event Dungeon - Hummel",[25495]="Подготовка к битве",
    [25500]="Слова, что нужно произнести",[26012]="Беда в храме Драконьего Покоя",[26013]="Нападение на святилище",
    [26034]="Сумеречный разрушитель",
}
-- END GENERATED QUESTTITLES

NS.ZONE_NAMES = {
    [0]="Other", [1]="Dun Morogh", [3]="Badlands", [4]="Blasted Lands", [8]="Swamp of Sorrows", [10]="Duskwood",
    [11]="Wetlands", [12]="Elwynn Forest", [14]="Durotar", [15]="Dustwallow Marsh", [16]="Azshara",
    [17]="The Barrens", [22]="Programmer Isle", [25]="Blackrock Mountain", [28]="Western Plaguelands",
    [33]="Stranglethorn Vale", [36]="Alterac Mountains", [38]="Loch Modan", [40]="Westfall",
    [41]="Deadwind Pass", [44]="Redridge Mountains", [45]="Arathi Highlands", [46]="Burning Steppes",
    [47]="The Hinterlands", [51]="Searing Gorge", [65]="Dragonblight", [66]="Zul'Drak", [67]="The Storm Peaks",
    [85]="Tirisfal Glades", [130]="Silverpine Forest",
    [131]="The Culling of Stratholme",
    [139]="Eastern Plaguelands", [141]="Teldrassil", [148]="Darkshore",
    [151]="Ulduar", [206]="Utgarde Keep",
    [209]="Shadowfang Keep", [210]="Icecrown", [215]="Mulgore", [236]="Dire Maul",
    [267]="Hillsbrad Foothills", [331]="Ashenvale", [357]="Feralas", [361]="Felwood", [393]="Darkspear Strand",
    [394]="Grizzly Hills", [400]="Thousand Needles", [405]="Desolace", [406]="Stonetalon Mountains",
    [440]="Tanaris", [490]="Un'Goro Crater", [491]="Razorfen Kraul", [493]="Moonglade",
    [495]="Howling Fjord", [618]="Winterspring", [702]="Rut'theran Village", [717]="The Stockade",
    [718]="Wailing Caverns", [719]="Blackfathom Deeps", [721]="Gnomeregan",
    [722]="Razorfen Downs", [796]="Scarlet Monastery", [1176]="Zul'Farrak",
    [1196]="Utgarde Pinnacle", [1216]="Timbermaw Hold", [1337]="Uldaman", [1377]="Silithus",
    [1477]="The Temple of Atal'Hakkar", [1497]="Undercity", [1519]="Stormwind City",
    [1537]="Ironforge", [1581]="The Deadmines", [1583]="Blackrock Spire",
    [1584]="Blackrock Depths", [1637]="Orgrimmar", [1638]="Thunder Bluff", [1657]="Darnassus",
    [1941]="Eversong Woods", [1977]="Zul'Gurub", [2017]="Stratholme", [2057]="Scholomance",
    [2100]="Maraudon", [2159]="Onyxia's Lair", [2257]="Deeprun Tram",
    [2437]="Ragefire Chasm", [2557]="Dire Maul", [2597]="Alterac Valley",
    [2677]="Blackwing Lair", [2717]="Molten Core", [2839]="Alterac Valley",
    [3277]="Warsong Gulch", [3358]="Arathi Basin", [3428]="Ahn'Qiraj",
    [3429]="Ruins of Ahn'Qiraj", [3430]="Eversong Woods", [3433]="Ghostlands", [3456]="Naxxramas",
    [3457]="Karazhan", [3483]="Hellfire Peninsula", [3487]="Silvermoon City", [3518]="Nagrand",
    [3519]="Terokkar Forest", [3520]="Shadowmoon Valley", [3521]="Zangarmarsh", [3522]="Blade's Edge Mountains",
    [3523]="Netherstorm", [3524]="Azuremyst Isle", [3525]="Bloodmyst Isle",
    [3535]="Hellfire Citadel",
    [3537]="Borean Tundra", [3557]="The Exodar", [3606]="Hyjal Summit",
    [3607]="Serpentshrine Cavern", [3679]="Skettis", [3688]="Auchindoun", [3703]="Shattrath City",
    [3711]="Sholazar Basin", [3715]="The Steamvault", [3716]="The Underbog",
    [3717]="The Slave Pens", [3789]="Shadow Labyrinth", [3790]="Auchenai Crypts",
    [3792]="Mana-Tombs", [3805]="Zul'Aman", [3820]="Eye of the Storm",
    [3836]="Magtheridon's Lair", [3845]="Tempest Keep", [3959]="Black Temple",
    [4075]="Sunwell Plateau", [4080]="Isle of Quel'Danas", [4100]="The Culling of Stratholme",
    [4120]="The Nexus", [4131]="Magisters' Terrace", [4196]="Drak'Tharon Keep", [4197]="Wintergrasp",
    [4228]="The Oculus", [4264]="Halls of Stone", [4272]="Halls of Lightning",
    [4273]="Ulduar", [4277]="Azjol-Nerub", [4342]="Acherus: The Ebon Hold",
    [4384]="Strand of the Ancients", [4395]="Dalaran",
    [4415]="The Violet Hold", [4416]="Gundrak", [4493]="The Obsidian Sanctum",
    [4494]="Ahn'kahet: The Old Kingdom", [4500]="The Eye of Eternity", [4613]="Dalaran City",
    [4710]="Isle of Conquest", [4722]="Trial of the Crusader",
    [4723]="Trial of the Champion", [4809]="The Forge of Souls",
    [4812]="Icecrown Citadel", [4813]="Pit of Saron", [4820]="Halls of Reflection",
    [4987]="The Ruby Sanctum",
}

NS.ZONE_RU = {
    ["Acherus: The Ebon Hold"]="Акерус: Черный оплот",["Ahn'Qiraj"]="Ан'Кираж",
    ["Ahn'kahet: The Old Kingdom"]="Ан'кахет: Старое Королевство",["Alterac Mountains"]="Альтеракские горы",
    ["Alterac Valley"]="Альтеракская долина",["Arathi Basin"]="Низина Арати",["Arathi Highlands"]="Нагорье Арати",
    ["Ashenvale"]="Ясеневый лес",["Auchenai Crypts"]="Аукенайские гробницы",["Auchindoun"]="Аукиндон",
    ["Azjol-Nerub"]="Азжол-Неруб",["Azshara"]="Азшара",["Azuremyst Isle"]="Остров Лазурной Дымки",
    ["Badlands"]="Бесплодные земли",["Black Temple"]="Черный храм",["Blackfathom Deeps"]="Непроглядная Пучина",
    ["Blackrock Depths"]="Глубины Черной Горы",["Blackrock Mountain"]="Черная гора",
    ["Blackrock Spire"]="Вершина Черной Горы",["Blackwing Lair"]="Логово Крыла Тьмы",
    ["Blade's Edge Mountains"]="Острогорье",["Blasted Lands"]="Выжженные земли",
    ["Bloodmyst Isle"]="Остров Кровавой Дымки",["Borean Tundra"]="Борейская тундра",
    ["Burning Steppes"]="Пылающие степи",["Dalaran"]="Даларан",["Dalaran City"]="Даларан",
    ["Darkshore"]="Темные берега",["Darkspear Strand"]="Берег Тёмного Копья",["Darnassus"]="Дарнасс",
    ["Deadwind Pass"]="Перевал Мертвого Ветра",["Deeprun Tram"]="Подземный поезд",["Desolace"]="Пустоши",
    ["Dire Maul"]="Забытый Город",["Dragonblight"]="Драконий Погост",["Drak'Tharon Keep"]="Крепость Драк'Тарон",
    ["Dun Morogh"]="Дун Морог",["Durotar"]="Дуротар",["Duskwood"]="Сумеречный лес",
    ["Dustwallow Marsh"]="Пылевые топи",["Eastern Plaguelands"]="Восточные Чумные земли",
    ["Elwynn Forest"]="Элвиннский лес",["Eversong Woods"]="Леса Вечной Песни",["Eye of the Storm"]="Око Бури",
    ["Felwood"]="Оскверненный лес",["Feralas"]="Фералас",["Ghostlands"]="Призрачные земли",["Gnomeregan"]="Гномреган",
    ["Grizzly Hills"]="Седые холмы",["Gundrak"]="Гундрак",["Halls of Lightning"]="Чертоги Молний",
    ["Halls of Reflection"]="Залы Отражений",["Halls of Stone"]="Чертоги Камня",
    ["Hellfire Citadel"]="Цитадель Адского Пламени",["Hellfire Peninsula"]="Полуостров Адского Пламени",
    ["Hillsbrad Foothills"]="Предгорья Хилсбрада",["Howling Fjord"]="Ревущий фьорд",
    ["Hyjal Summit"]="Вершина Хиджала",["Icecrown"]="Ледяная Корона",["Icecrown Citadel"]="Цитадель Ледяной Короны",
    ["Ironforge"]="Стальгорн",["Isle of Conquest"]="Остров Завоеваний",["Isle of Quel'Danas"]="Остров Кель'Данас",
    ["Karazhan"]="Каражан",["Loch Modan"]="Лок Модан",["Magisters' Terrace"]="Терраса Магистров",
    ["Magtheridon's Lair"]="Логово Магтеридона",["Mana-Tombs"]="Гробницы маны",["Maraudon"]="Марадон",
    ["Molten Core"]="Огненные Недра",["Moonglade"]="Лунная поляна",["Mulgore"]="Мулгор",["Nagrand"]="Награнд",
    ["Naxxramas"]="Наксрамас",["Netherstorm"]="Пустоверть",["Onyxia's Lair"]="Логово Ониксии",
    ["Orgrimmar"]="Оргриммар",["Other"]="Другое",["Pit of Saron"]="Яма Сарона",
    ["Programmer Isle"]="Остров программистов",["Ragefire Chasm"]="Огненная пропасть",
    ["Razorfen Downs"]="Курганы Иглошкурых",["Razorfen Kraul"]="Лабиринты Иглошкурых",
    ["Redridge Mountains"]="Красногорье",["Ruins of Ahn'Qiraj"]="Руины Ан'Киража",
    ["Rut'theran Village"]="Деревня Рут'теран",["Scarlet Monastery"]="Монастырь Алого Ордена",
    ["Scholomance"]="Некроситет",["Searing Gorge"]="Тлеющее ущелье",["Serpentshrine Cavern"]="Змеиное святилище",
    ["Shadow Labyrinth"]="Темный лабиринт",["Shadowfang Keep"]="Крепость Темного Клыка",
    ["Shadowmoon Valley"]="Долина Призрачной Луны",["Shattrath City"]="Шаттрат",["Sholazar Basin"]="Низина Шолазар",
    ["Silithus"]="Силитус",["Silvermoon City"]="Луносвет",["Silverpine Forest"]="Серебряный бор",
    ["Skettis"]="Скеттис",["Stonetalon Mountains"]="Когтистые горы",["Stormwind City"]="Штормград",
    ["Strand of the Ancients"]="Берег Древних",["Stranglethorn Vale"]="Тернистая долина",["Stratholme"]="Стратхольм",
    ["Sunwell Plateau"]="Плато Солнечного Колодца",["Swamp of Sorrows"]="Болото Печали",["Tanaris"]="Танарис",
    ["Teldrassil"]="Тельдрассил",["Tempest Keep"]="Крепость Бурь",["Terokkar Forest"]="Лес Тероккар",
    ["The Barrens"]="Степи",["The Culling of Stratholme"]="Очищение Стратхольма",["The Deadmines"]="Мертвые Копи",
    ["The Exodar"]="Экзодар",["The Eye of Eternity"]="Око Вечности",["The Forge of Souls"]="Кузня Душ",
    ["The Hinterlands"]="Внутренние земли",["The Nexus"]="Нексус",["The Obsidian Sanctum"]="Обсидиановое святилище",
    ["The Oculus"]="Окулус",["The Ruby Sanctum"]="Рубиновое святилище",["The Slave Pens"]="Узилище",
    ["The Steamvault"]="Паровое подземелье",["The Stockade"]="Тюрьма",["The Storm Peaks"]="Грозовая Гряда",
    ["The Temple of Atal'Hakkar"]="Храм Атал'Хаккар",["The Underbog"]="Нижетопь",
    ["The Violet Hold"]="Аметистовая крепость",["Thousand Needles"]="Тысяча Игл",["Thunder Bluff"]="Громовой Утес",
    ["Timbermaw Hold"]="Древобрюхи",["Tirisfal Glades"]="Тирисфальские леса",
    ["Trial of the Champion"]="Испытание чемпиона",["Trial of the Crusader"]="Испытание крестоносца",
    ["Uldaman"]="Ульдаман",["Ulduar"]="Ульдуар",["Un'Goro Crater"]="Кратер Ун'Горо",["Undercity"]="Подгород",
    ["Utgarde Keep"]="Крепость Утгард",["Utgarde Pinnacle"]="Pináculo Utgarde",["Wailing Caverns"]="Пещеры Стенаний",
    ["Warsong Gulch"]="Ущелье Песни Войны",["Western Plaguelands"]="Западные Чумные земли",
    ["Westfall"]="Западный Край",["Wetlands"]="Болотина",["Wintergrasp"]="Озеро Ледяных Оков",
    ["Winterspring"]="Зимние Ключи",["Zangarmarsh"]="Зангартопь",["Zul'Aman"]="Зул'Аман",["Zul'Drak"]="Зул'Драк",
    ["Zul'Farrak"]="Зул'Фаррак",["Zul'Gurub"]="Зул'Гуруб",["Completed"]="Выполненные",
}

-- Russian names of the talent trees (English name -> Russian; a name shared by classes reads the same in
-- Russian for each of them) and of the other spellbook groups.
NS.SPEC_RU = {
    ["Arms"] = "Оружие", ["Fury"] = "Неистовство", ["Protection"] = "Защита",
    ["Holy"] = "Свет", ["Retribution"] = "Воздаяние",
    ["Beast Mastery"] = "Повелитель зверей", ["Marksmanship"] = "Стрельба", ["Survival"] = "Выживание",
    ["Assassination"] = "Ликвидация", ["Combat"] = "Бой", ["Subtlety"] = "Скрытность",
    ["Discipline"] = "Послушание", ["Shadow"] = "Тьма",
    ["Blood"] = "Кровь", ["Frost"] = "Лёд", ["Unholy"] = "Нечестивость",
    ["Elemental"] = "Стихии", ["Enhancement"] = "Совершенствование", ["Restoration"] = "Исцеление",
    ["Arcane"] = "Тайная магия", ["Fire"] = "Огонь",
    ["Affliction"] = "Колдовство", ["Demonology"] = "Демонология", ["Destruction"] = "Разрушение",
    ["Balance"] = "Баланс", ["Feral Combat"] = "Сила зверя",
    ["Professions"] = "Профессии", ["Other"] = "Другое",
}

--- "English (Русский)" when a Russian name is known, else just the English one.
NS.WithRu = function(name, tbl)
    local ru = tbl[name]
    if ru and ru ~= name then return name .. " (" .. ru .. ")" end
    return name
end


--- The quest lists persist (AltBot_SavedVars.questCache), a wild-class bot's is wiped at logout.
NS.SaveQuestCache = function(key, list)
    if not AltBot_SavedVars then return end
    AltBot_SavedVars.questCache = AltBot_SavedVars.questCache or {}
    local out = {}
    for i, q in ipairs(list) do out[i] = { id = q.id, status = q.status, name = q.name, link = q.link } end
    AltBot_SavedVars.questCache[key] = out
end

NS.LoadQuestCache = function(key)
    if NS.botQuestState[key] then return end
    local saved = AltBot_SavedVars and AltBot_SavedVars.questCache and AltBot_SavedVars.questCache[key]
    if saved then NS.botQuestState[key] = saved end
end

--- The master's own quest ids: a set read from his quest log (the "[N]" column counts him too).
NS.MasterQuestSet = function()
    local set = {}
    for i = 1, GetNumQuestLogEntries() do
        local _, _, _, _, isHeader = GetQuestLogTitle(i)
        if not isHeader then
            local id = tonumber((GetQuestLink(i) or ""):match("quest:(%d+)"))
            if id then set[id] = true end
        end
    end
    return set
end

--- How many tracked bots have quest `id` in their (last known) quest log.
NS.QuestBotCount = function(id)
    local n = 0
    for key in pairs(NS.bots) do
        NS.LoadQuestCache(key)
        for _, q in ipairs(NS.botQuestState[key] or {}) do
            if q.id == id then n = n + 1 break end
        end
    end
    return n
end

-- Quest row right click: no menu - the quest is DROPPED at once ("drop <questlink>" to the bot; the
-- exact argument format mod-playerbots expects isn't documented, so the real hyperlink is used as the
-- safest guess) and the window is refreshed: the quest leaves the list immediately and the bot's real
-- list is read again a moment later (per explicit user direction).
-- ============================================================
NS.DropQuestRow = function(row)
    if not row.questId or not row.botName then return end
    local botName, questId = row.botName, row.questId
    SendBotCommand(botName, "drop " .. (row.questLink or tostring(questId)))
    local key = strlower(botName)
    local list = NS.botQuestState[key] or {}
    for i = #list, 1, -1 do
        if list[i].id == questId then table.remove(list, i) end
    end
    NS.SaveQuestCache(key, list)
    NS.RepaintOpenQuestWindows()
    NS.After(2, function() NS.FetchBotQuests(botName) end)
end

--- Whispers "quests all" to fetch/refresh one bot's quest list.
NS.FetchBotQuests = function(botName)
    local key = strlower(botName)
    -- One hold on the bot's polling per outstanding fetch (a second call while one is
    -- still collecting must not Begin again - only one End ever follows).
    if not questAwaiting[key] then NS.BeginDetailFetch(botName) end
    questAwaiting[key] = { quests = {}, status = "I", timer = 0 }
    SendBotCommand(botName, "quests all")
end

local QUEST_STATUS_COLOR = {
    I = { 1.0,   1.0,   0.0   },  -- Incomplete - yellow
    C = { 0.251, 0.749, 0.251 },  -- Complete - green
}

--- Builds (once per bot) or returns the existing quest log window for `botName`.
local function GetOrCreateQuestFrame(botName)
    local key = strlower(botName)
    local f = NS.botQuestFrames[key]
    if f then return f end

    f = CreateFrame("Frame", "AltBotQuests_" .. key, UIParent)
    f.botName = botName
    f:SetSize(QUEST_FRAME_W, 460)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    NS.RememberWindowPosition(f, "quests", botName)
    f:SetScript("OnMouseDown", function(self) self:Raise() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0, 0, 0, 1)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText(botName .. "'s Quests")
    f.title = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    f.scroll = CreateFrame("ScrollFrame", "AltBotQuestScroll_" .. key, f, "UIPanelScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -38)
    f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 18)
    f.content = CreateFrame("Frame", nil, f.scroll)
    f.content:SetSize(QUEST_FRAME_W - 60, 10)
    f.scroll:SetScrollChild(f.content)
    f.rows = {}

    f:Hide()
    NS.botQuestFrames[key] = f
    return f
end

--- One table row (created on demand, reused): id | [bots] | link + Russian title; a header row is just text.
NS.GetQuestRow = function(f, i)
    local row = f.rows[i]
    if row then return row end
    local width = QUEST_FRAME_W - 60
    row = CreateFrame("Button", nil, f.content)
    row:SetSize(width, QUEST_ROW_H)
    row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -(i - 1) * QUEST_ROW_H)
    row.idText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.idText:SetWidth(QUEST_ID_W)
    row.idText:SetJustifyH("RIGHT")
    row.idText:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.cntText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.cntText:SetWidth(NS.QUEST_CNT_W)
    row.cntText:SetJustifyH("CENTER")
    row.cntText:SetPoint("LEFT", row.idText, "RIGHT", 4, 0)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.text:SetJustifyH("LEFT")
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints(row)
    row.hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    row.hl:SetBlendMode("ADD")
    row.botName = f.botName
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnEnter", function(self)
        if not self.questLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.questLink)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self, button)
        if not self.questId then return end
        if IsShiftKeyDown() then
            NS.InsertLinkIntoChat(self.questLink)   -- shift-click: the link goes into the chat
        elseif button == "RightButton" then
            NS.DropQuestRow(self)
        end
    end)
    f.rows[i] = row
    return row
end

--- Paints `key`'s quest window from its last known list.
NS.PaintQuestWindow = function(key)
    local f = NS.botQuestFrames[key]
    if not f then return end
    local quests = NS.botQuestState[key] or {}

    local done, byZone, zoneNames = {}, {}, {}
    for _, q in ipairs(quests) do
        if q.status == "C" then
            done[#done + 1] = q
        else
            local zone = NS.ZONE_NAMES[NS.QUEST_ZONE[q.id] or 0] or "Other"
            if not byZone[zone] then
                byZone[zone] = {}
                zoneNames[#zoneNames + 1] = zone
            end
            byZone[zone][#byZone[zone] + 1] = q
        end
    end
    local function byName(a, b) return strlower(a.name or "") < strlower(b.name or "") end
    table.sort(done, byName)
    table.sort(zoneNames, function(a, b) return strlower(a) < strlower(b) end)

    local entries = {}
    for _, zone in ipairs(zoneNames) do
        table.sort(byZone[zone], byName)
        entries[#entries + 1] = { header = zone }
        for _, q in ipairs(byZone[zone]) do entries[#entries + 1] = { quest = q } end
    end
    -- the completed quests last, per explicit user direction
    if #done > 0 then
        entries[#entries + 1] = { header = "Completed" }
        for _, q in ipairs(done) do entries[#entries + 1] = { quest = q } end
    end
    if #entries == 0 then entries[1] = { header = "No quests." } end

    local idEnd = QUEST_ID_W + 4 + NS.QUEST_CNT_W + 6
    local masterQuests = NS.MasterQuestSet()
    for i, e in ipairs(entries) do
        local row = NS.GetQuestRow(f, i)
        row.text:ClearAllPoints()
        if e.header then
            row.questId, row.questLink = nil, nil
            row.idText:SetText("")
            row.cntText:SetText("")
            row.hl:Hide()
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetText("|cffffd100" .. NS.WithRu(e.header, NS.ZONE_RU) .. ":|r")
        else
            local q = e.quest
            local color = QUEST_STATUS_COLOR[q.status] or QUEST_STATUS_COLOR.I
            row.questId, row.questLink = q.id, q.link
            row.idText:SetTextColor(color[1], color[2], color[3])
            row.idText:SetText(q.id)
            row.cntText:SetTextColor(0.8, 0.8, 1)
            -- every tracked bot that has the quest, this one included, plus the master himself
            row.cntText:SetText("[" .. (NS.QuestBotCount(q.id) + (masterQuests[q.id] and 1 or 0)) .. "]")
            row.hl:Show()
            -- the link, then the Russian title from QuestChromeCraft (when it differs)
            local ru = NS.QUEST_TITLE_RU[q.id]
            local text = q.link or q.name or ("Quest " .. tostring(q.id))
            if ru and ru ~= "" and ru ~= q.name then text = text .. " " .. ru end
            row.text:SetPoint("LEFT", row, "LEFT", idEnd, 0)
            row.text:SetTextColor(color[1], color[2], color[3])
            row.text:SetText(text)
        end
        row:Show()
    end
    for i = #entries + 1, #f.rows do
        f.rows[i].questId = nil
        f.rows[i]:Hide()
    end
    f.content:SetHeight(math.max(10, #entries * QUEST_ROW_H))
end

--- Repaints every OPEN quest window (a bot's list changed, so the counts may have too).
NS.RepaintOpenQuestWindows = function()
    for key, f in pairs(NS.botQuestFrames) do
        if f:IsShown() then NS.PaintQuestWindow(key) end
    end
end

--- Opens `botName`'s quest window instantly from the saved lists and refreshes them: this bot's
--- list first, then every other tracked bot's (their lists feed the "[N]" column).
NS.ToggleBotQuestLog = function(botName)
    local f = GetOrCreateQuestFrame(botName)
    if f:IsShown() then
        f:Hide()
        return
    end
    local key = strlower(botName)
    for k in pairs(NS.bots) do NS.LoadQuestCache(k) end
    NS.PaintQuestWindow(key)
    f:Show()
    NS.FetchBotQuests(botName)
    NS.FetchAllBotQuests(key)
end

--- Refreshes the quest list of every tracked bot (except `exceptKey`), one every half second.
NS.FetchAllBotQuests = function(exceptKey)
    local i = 0
    for _, k in ipairs(NS.rosterOrder) do
        local entry = NS.bots[k]
        if entry and k ~= exceptKey then
            i = i + 1
            NS.After(i * 0.5, function() NS.FetchBotQuests(entry.name) end)
        end
    end
end

--- Patches the master's NATIVE quest log, per explicit user direction: the number in [brackets] in
--- front of a quest (the row's "GroupMates" label: the group's members that have it) becomes the
--- number of bots in the raid that have it, the master included - the same figure as the "[N]"
--- column of our quest windows.
NS.PatchNativeQuestLog = function()
    if not QuestLogFrame or not QuestLogFrame:IsShown() then return end
    -- title -> quest index of the master's log (the buttons are matched by their title text)
    local indexByTitle = {}
    for q = 1, GetNumQuestLogEntries() do
        local title, _, _, _, isHeader = GetQuestLogTitle(q)
        if title and not isHeader then indexByTitle[title] = q end
    end
    for i = 1, 40 do
        -- this client's rows: QuestLogScrollFrameButton<N> with a "...GroupMates" label ("[4]")
        local button = _G["QuestLogScrollFrameButton" .. i]
        if not button then break end
        local label = _G["QuestLogScrollFrameButton" .. i .. "GroupMates"]
        if label and button:IsShown() then
            local title = strtrim(button:GetText() or "")
            local questIndex = indexByTitle[title]
            if questIndex then
                local id = tonumber((GetQuestLink(questIndex) or ""):match("quest:(%d+)"))
                if id then
                    -- bots of the raid with the quest + the master himself (it is in his own log)
                    local text = "[" .. (NS.QuestBotCount(id) + 1) .. "]"
                    if label:GetText() ~= text then label:SetText(text) end
                    label:Show()
                end
            end
        end
    end
end

-- This client has no known update function to hook for the rows, so while the log is open the rows
-- are checked a few times a second (SetText is only called when the number changes).
NS.questLogPatchFrame = CreateFrame("Frame")
NS.questLogPatchFrame:SetScript("OnUpdate", function(self, dt)
    self.acc = (self.acc or 0) + dt
    if self.acc < 0.3 then return end
    self.acc = 0
    NS.PatchNativeQuestLog()
end)

if QuestLog_Update then hooksecurefunc("QuestLog_Update", NS.PatchNativeQuestLog) end
if QuestLogFrame then
    QuestLogFrame:HookScript("OnShow", function()
        for k in pairs(NS.bots) do NS.LoadQuestCache(k) end
        NS.PatchNativeQuestLog()
        NS.FetchAllBotQuests(nil)   -- fresh lists, the numbers follow as they arrive
    end)
end

-- The master's own quest log changed (accepted/finished/dropped a quest): the counts change too.
NS.questLogWatcher = CreateFrame("Frame")
NS.questLogWatcher:RegisterEvent("QUEST_LOG_UPDATE")
NS.questLogWatcher:SetScript("OnEvent", function(self) self.dirty = true end)
NS.questLogWatcher:SetScript("OnUpdate", function(self, dt)
    if not self.dirty then return end
    self.acc = (self.acc or 0) + dt
    if self.acc < 1 then return end
    self.acc, self.dirty = 0, false
    NS.RepaintOpenQuestWindows()
end)

--- A bot's quest list is complete: keep it, save it, repaint whatever is open.
NS.FinishQuestList = function(key, list)
    NS.botQuestState[key] = list
    NS.SaveQuestCache(key, list)
    NS.RepaintOpenQuestWindows()
    if QuestLog_Update and QuestLogFrame and QuestLogFrame:IsShown() then QuestLog_Update() end
end

local questWatcher = CreateFrame("Frame")
questWatcher:RegisterEvent("CHAT_MSG_WHISPER")
questWatcher:SetScript("OnEvent", function(self, event, msg, sender)
    local key = strlower(sender or "")
    local collecting = questAwaiting[key]
    if not collecting then return end
    collecting.timer = 0
    -- Re-extend the chat-hiding window too: SendBotCommand's STEP_DELAY (2s) is shorter than this
    -- collector's STATS_TIMEOUT (5s) silence window, so a longer "quests all" stream otherwise
    -- leaks its trailing lines into chat.
    NS.blockedBotNames[key] = true
    NS.After(NS.STATS_TIMEOUT, function() NS.blockedBotNames[key] = nil end)

    local id = tonumber(msg:match("|Hquest:(%d+):"))
    if id then
        collecting.quests[#collecting.quests + 1] = {
            id     = id,
            status = collecting.status,
            name   = msg:match("%[(.-)%]"),
            link   = msg:match("(|c%x+|Hquest:[^|]+|h%[.-%]|h|r)"),
        }
    elseif msg:find("Summary", 1, true) or msg:match("^%s*Total:") then
        questAwaiting[key] = nil
        NS.EndDetailFetch(key)
        NS.FinishQuestList(key, collecting.quests)
    elseif msg:find("Incomplet", 1, true) then
        collecting.status = "I"
    elseif msg:find("Complet", 1, true) then
        collecting.status = "C"
    end
end)

-- Fallback finalize: if the "Summary"/"Total:" line never arrives (older mod-playerbots builds, or a
-- lost reply), finalize on silence like the inventory/stats collectors do.
local questTicker = CreateFrame("Frame")
questTicker:SetScript("OnUpdate", function(self, dt)
    local done
    for key, collecting in pairs(questAwaiting) do
        collecting.timer = collecting.timer + dt
        if collecting.timer >= NS.STATS_TIMEOUT then
            done = done or {}
            done[#done + 1] = key
        end
    end
    for _, key in ipairs(done or {}) do   -- outside the traversal
        local collecting = questAwaiting[key]
        questAwaiting[key] = nil
        NS.EndDetailFetch(key)
        NS.FinishQuestList(key, collecting.quests)
    end
end)

-- ============================================================
-- Bot spellbook window - per bot, opened from the level row of its board column. The list
-- comes from the bot's own reply to "spells" (every spell link found in its whispers).
-- Left click on a spell = the bot casts it ("cast <name>"); right click -> "Macro": makes
-- (or updates) a macro "/w <bot> cast <name>" and puts it on the cursor, so the master can
-- drop it on an action bar and fire it at the right moment of a fight (per explicit user
-- direction). The lists live in memory only.
-- ============================================================
-- BEGIN GENERATED SPELLTABS (tools/spelltabs_generate.py rewrites everything up to END)
-- GENERATED from Wowhead (WotLK class abilities + talent spells): which talent tree (spec) each
-- class spell belongs to. Keys are lowercase English spell names. Value = {tree, level, schools}: tree 1..3 = the class's trees
-- in order of specs[], 0 = class spell outside any tree; level = lowest rank level; schools = bitmask
-- (1 physical, 2 holy, 4 fire, 8 nature, 16 frost, 32 shadow, 64 arcane). Regenerate, do not edit by hand.
NS.spellTabs = {
    WARRIOR = {
        specs = { "Arms", "Fury", "Protection" },
        spells = {
            ["anger management"]={1,0,1}, ["anticipation"]={3,0,1}, ["armored to the teeth"]={2,0,1},
            ["battle shout"]={2,1,1}, ["battle stance"]={1,1,1}, ["berserker rage"]={2,32,1},
            ["berserker stance"]={2,30,1}, ["bladestorm"]={1,0,1}, ["blood craze"]={2,0,1},
            ["blood frenzy"]={1,0,1}, ["bloodrage"]={3,10,1}, ["bloodsurge"]={2,0,1}, ["bloodthirst"]={2,0,1},
            ["booming voice"]={2,0,1}, ["challenging shout"]={2,26,1}, ["charge"]={1,4,1}, ["cleave"]={2,20,1},
            ["commanding presence"]={2,0,1}, ["commanding shout"]={2,68,1}, ["concussion blow"]={3,0,1},
            ["critical block"]={3,0,1}, ["cruelty"]={2,0,1}, ["damage shield"]={3,0,1}, ["death wish"]={2,0,1},
            ["deep wounds"]={1,0,1}, ["defensive stance"]={3,10,1}, ["deflection"]={1,0,1},
            ["demoralizing shout"]={2,14,1}, ["devastate"]={3,0,1}, ["disarm"]={3,18,1},
            ["dual wield specialization"]={2,0,1}, ["endless rage"]={1,0,1}, ["enrage"]={2,0,1},
            ["enraged regeneration"]={2,75,1}, ["execute"]={2,24,1}, ["flurry"]={2,0,1},
            ["focused rage"]={3,0,1}, ["furious attacks"]={2,0,1}, ["gag order"]={3,0,1},
            ["hamstring"]={1,8,1}, ["heroic fury"]={2,0,1}, ["heroic strike"]={1,1,1},
            ["heroic throw"]={1,80,1}, ["impale"]={1,0,1}, ["improved berserker rage"]={2,0,1},
            ["improved berserker stance"]={2,0,1}, ["improved bloodrage"]={3,0,1}, ["improved charge"]={1,0,1},
            ["improved cleave"]={2,0,1}, ["improved defensive stance"]={3,0,1},
            ["improved demoralizing shout"]={2,0,1}, ["improved disarm"]={3,0,1},
            ["improved disciplines"]={3,0,1}, ["improved execute"]={2,0,1}, ["improved hamstring"]={1,0,1},
            ["improved heroic strike"]={1,0,1}, ["improved intercept"]={2,0,1},
            ["improved mortal strike"]={1,0,1}, ["improved overpower"]={1,0,1}, ["improved rend"]={1,0,1},
            ["improved revenge"]={3,0,1}, ["improved slam"]={2,0,1}, ["improved spell reflection"]={3,0,1},
            ["improved thunder clap"]={3,0,1}, ["improved whirlwind"]={2,0,1}, ["incite"]={3,0,1},
            ["intensify rage"]={2,0,1}, ["intercept"]={2,30,1}, ["intervene"]={3,70,1},
            ["intimidating shout"]={2,22,1}, ["iron will"]={1,0,1}, ["juggernaut"]={1,0,1},
            ["last stand"]={3,0,1}, ["mace specialization"]={1,0,1}, ["mocking blow"]={1,16,1},
            ["mortal strike"]={1,0,1}, ["one-handed weapon specialization"]={3,0,1}, ["overpower"]={1,12,1},
            ["piercing howl"]={2,0,1}, ["poleaxe specialization"]={1,0,1}, ["precision"]={2,0,1},
            ["pummel"]={2,38,1}, ["puncture"]={3,0,1}, ["rampage"]={2,0,1}, ["recklessness"]={2,50,1},
            ["rend"]={1,4,1}, ["retaliation"]={1,20,1}, ["revenge"]={3,14,1}, ["safeguard"]={3,0,1},
            ["second wind"]={1,0,1}, ["shattering throw"]={1,71,1}, ["shield bash"]={3,12,1},
            ["shield block"]={3,16,1}, ["shield mastery"]={3,0,1}, ["shield slam"]={3,40,1},
            ["shield specialization"]={3,0,1}, ["shield wall"]={3,28,1}, ["shockwave"]={3,0,1},
            ["slam"]={2,30,1}, ["spell reflection"]={3,64,1}, ["stance mastery"]={3,20,1},
            ["strength of arms"]={1,0,1}, ["sudden death"]={1,0,1}, ["sunder armor"]={3,10,1},
            ["sweeping strikes"]={1,0,1}, ["sword and board"]={3,0,1}, ["sword specialization"]={1,0,1},
            ["tactical mastery"]={1,0,1}, ["taste for blood"]={1,0,1}, ["taunt"]={3,10,1},
            ["thunder clap"]={1,6,1}, ["titan's grip"]={2,0,1}, ["toughness"]={3,0,1}, ["trauma"]={1,0,1},
            ["two-handed weapon specialization"]={1,0,1}, ["unbridled wrath"]={2,0,1},
            ["unending fury"]={2,0,1}, ["unrelenting assault"]={1,0,1}, ["victory rush"]={2,6,1},
            ["vigilance"]={3,0,1}, ["vitality"]={3,0,1}, ["warbringer"]={3,0,1}, ["weapon mastery"]={1,0,1},
            ["whirlwind"]={2,36,1}, ["wrecking crew"]={1,0,1},
        },
    },
    PALADIN = {
        specs = { "Holy", "Protection", "Retribution" },
        spells = {
            ["anticipation"]={2,0,1}, ["ardent defender"]={2,0,1}, ["aura mastery"]={1,0,1},
            ["avenger's shield"]={2,0,2}, ["avenging wrath"]={3,70,2}, ["beacon of light"]={1,0,2},
            ["benediction"]={3,0,1}, ["blessed hands"]={1,0,1}, ["blessed life"]={1,0,1},
            ["blessing of kings"]={2,20,2}, ["blessing of might"]={3,4,2}, ["blessing of sanctuary"]={2,0,2},
            ["blessing of wisdom"]={1,14,2}, ["blood corruption"]={3,64,2}, ["charger"]={1,40,2},
            ["cleanse"]={1,42,2}, ["combat expertise"]={2,0,1}, ["concentration aura"]={1,22,2},
            ["consecration"]={1,20,2}, ["conviction"]={3,0,1}, ["crusade"]={3,0,1}, ["crusader aura"]={3,62,2},
            ["crusader strike"]={3,0,1}, ["deflection"]={3,0,1}, ["devotion aura"]={2,1,2},
            ["divine favor"]={1,0,2}, ["divine guardian"]={2,0,1}, ["divine illumination"]={1,0,2},
            ["divine intellect"]={1,0,1}, ["divine intervention"]={2,30,2}, ["divine plea"]={1,71,2},
            ["divine protection"]={2,6,2}, ["divine purpose"]={3,0,1}, ["divine sacrifice"]={2,0,1},
            ["divine shield"]={2,34,2}, ["divine storm"]={3,0,1}, ["divine strength"]={2,0,1},
            ["divinity"]={2,0,1}, ["enlightened judgements"]={1,0,1}, ["exorcism"]={1,20,2},
            ["eye for an eye"]={3,0,1}, ["fanaticism"]={3,0,1}, ["fire resistance aura"]={2,36,2},
            ["flash of light"]={1,20,2}, ["frost resistance aura"]={2,32,2}, ["glyph of holy light"]={1,1,2},
            ["greater blessing of kings"]={2,60,2}, ["greater blessing of might"]={3,52,2},
            ["greater blessing of sanctuary"]={2,60,2}, ["greater blessing of wisdom"]={1,54,2},
            ["guarded by the light"]={2,0,1}, ["guardian's favor"]={2,0,1}, ["hammer of justice"]={2,8,2},
            ["hammer of the righteous"]={2,0,2}, ["hammer of wrath"]={3,44,2}, ["hand of freedom"]={2,18,2},
            ["hand of protection"]={2,10,2}, ["hand of reckoning"]={2,16,2}, ["hand of sacrifice"]={2,46,2},
            ["hand of salvation"]={2,26,2}, ["healing light"]={1,0,1}, ["heart of the crusader"]={3,0,1},
            ["holy guidance"]={1,0,1}, ["holy light"]={1,1,2}, ["holy power"]={1,0,1}, ["holy shield"]={2,0,2},
            ["holy shock"]={1,0,2}, ["holy wrath"]={1,50,2}, ["illumination"]={1,0,1},
            ["improved blessing of might"]={3,0,1}, ["improved blessing of wisdom"]={1,0,1},
            ["improved concentration aura"]={1,0,1}, ["improved devotion aura"]={2,0,1},
            ["improved hammer of justice"]={2,0,1}, ["improved judgements"]={3,0,1},
            ["improved lay on hands"]={1,0,1}, ["improved righteous fury"]={2,0,1},
            ["infusion of light"]={1,0,1}, ["judgement of corruption"]={3,64,2},
            ["judgement of justice"]={3,28,2}, ["judgement of light"]={3,4,2},
            ["judgement of wisdom"]={3,12,2}, ["judgements of the just"]={2,0,1},
            ["judgements of the pure"]={1,0,1}, ["judgements of the wise"]={3,0,1}, ["lay on hands"]={1,10,2},
            ["light's grace"]={1,0,1}, ["one-handed weapon specialization"]={0,0,1}, ["pure of heart"]={1,0,1},
            ["purify"]={1,8,2}, ["purifying power"]={1,0,1}, ["pursuit of justice"]={3,0,1},
            ["reckoning"]={2,0,1}, ["redemption"]={1,12,2}, ["redoubt"]={2,0,1}, ["repentance"]={3,0,2},
            ["retribution aura"]={3,16,2}, ["righteous defense"]={2,14,2}, ["righteous fury"]={2,16,2},
            ["righteous vengeance"]={3,0,1}, ["sacred cleansing"]={1,0,1}, ["sacred duty"]={2,0,1},
            ["sacred shield"]={1,80,2}, ["sanctified light"]={1,0,1}, ["sanctified retribution"]={3,0,1},
            ["sanctified wrath"]={3,0,1}, ["sanctity of battle"]={3,0,1}, ["seal of command"]={3,0,2},
            ["seal of corruption"]={3,64,2}, ["seal of justice"]={2,22,2}, ["seal of light"]={1,30,2},
            ["seal of righteousness"]={1,1,2}, ["seal of vengeance"]={3,64,2}, ["seal of wisdom"]={1,38,2},
            ["seals of the pure"]={1,0,1}, ["sense undead"]={1,20,2}, ["shadow resistance aura"]={2,28,2},
            ["sheath of light"]={3,0,1}, ["shield of righteousness"]={2,75,2},
            ["shield of the templar"]={2,0,1}, ["spiritual attunement"]={2,0,2}, ["spiritual focus"]={1,0,1},
            ["stoicism"]={2,0,1}, ["summon charger"]={1,40,2}, ["summon warhorse"]={1,20,2},
            ["swift retribution"]={3,0,1}, ["the art of war"]={3,0,1}, ["touched by the light"]={2,0,1},
            ["toughness"]={2,0,1}, ["turn evil"]={1,24,2}, ["two-handed weapon specialization"]={3,0,1},
            ["unyielding faith"]={1,0,1}, ["vengeance"]={3,0,1}, ["vindication"]={3,0,1},
            ["warhorse"]={1,20,2},
        },
    },
    HUNTER = {
        specs = { "Beast Mastery", "Marksmanship", "Survival" },
        spells = {
            ["aimed shot"]={2,0,1}, ["animal handler"]={1,0,1}, ["arcane shot"]={2,6,64},
            ["aspect mastery"]={1,0,1}, ["aspect of the beast"]={1,30,8}, ["aspect of the cheetah"]={1,16,8},
            ["aspect of the dragonhawk"]={1,74,8}, ["aspect of the hawk"]={1,10,8},
            ["aspect of the monkey"]={1,4,8}, ["aspect of the pack"]={1,40,8},
            ["aspect of the viper"]={1,20,8}, ["aspect of the wild"]={1,46,8}, ["auto shot"]={2,1,1},
            ["barrage"]={2,0,1}, ["beast lore"]={1,24,8}, ["beast mastery"]={1,0,1},
            ["bestial discipline"]={1,0,1}, ["bestial wrath"]={1,0,1}, ["black arrow"]={3,57,32},
            ["call pet"]={1,10,1}, ["call stabled pet"]={1,80,1}, ["careful aim"]={2,0,1},
            ["catlike reflexes"]={1,0,1}, ["chimera shot"]={2,0,8}, ["cobra strikes"]={1,0,1},
            ["combat experience"]={2,0,1}, ["concussive barrage"]={2,0,1}, ["concussive shot"]={2,8,64},
            ["counterattack"]={3,0,1}, ["deflection"]={3,0,1}, ["deterrence"]={3,60,1}, ["disengage"]={3,20,1},
            ["dismiss pet"]={1,10,1}, ["distracting shot"]={2,12,64}, ["eagle eye"]={1,14,64},
            ["efficiency"]={2,0,1}, ["endurance training"]={1,0,1}, ["entrapment"]={3,0,1},
            ["explosive shot"]={3,0,4}, ["explosive trap"]={3,34,4}, ["expose weakness"]={3,0,64},
            ["eyes of the beast"]={1,14,8}, ["feed pet"]={1,10,1}, ["feign death"]={3,30,1},
            ["ferocious inspiration"]={1,0,1}, ["ferocity"]={1,0,1}, ["flare"]={2,32,64},
            ["focused aim"]={2,0,1}, ["focused fire"]={1,0,1}, ["freezing arrow"]={3,80,16},
            ["freezing trap"]={3,20,16}, ["frenzy"]={1,0,1}, ["frost trap"]={3,28,16},
            ["go for the throat"]={2,0,1}, ["hawk eye"]={3,0,1}, ["hunter vs. wild"]={3,0,1},
            ["hunter's mark"]={2,6,64}, ["hunting party"]={3,0,1}, ["immolation trap"]={3,16,4},
            ["improved arcane shot"]={2,0,1}, ["improved aspect of the hawk"]={1,0,1},
            ["improved aspect of the monkey"]={1,0,1}, ["improved barrage"]={2,0,1},
            ["improved concussive shot"]={2,0,1}, ["improved hunter's mark"]={2,0,1},
            ["improved mend pet"]={1,0,1}, ["improved revive pet"]={1,0,1}, ["improved steady shot"]={2,0,1},
            ["improved stings"]={2,0,1}, ["improved tracking"]={3,0,1}, ["intimidation"]={1,0,8},
            ["invigoration"]={1,0,1}, ["kill command"]={1,66,1}, ["kill shot"]={2,71,1},
            ["killer instinct"]={3,0,1}, ["kindred spirits"]={1,0,1}, ["lethal shots"]={2,0,1},
            ["lightning reflexes"]={3,0,1}, ["lock and load"]={3,0,1}, ["longevity"]={1,0,1},
            ["marked for death"]={2,0,1}, ["master marksman"]={2,0,1}, ["master tactician"]={3,0,64},
            ["master's call"]={1,75,1}, ["mend pet"]={1,12,8}, ["misdirection"]={3,70,1},
            ["mongoose bite"]={3,16,1}, ["mortal shots"]={2,0,1}, ["multi-shot"]={2,18,1},
            ["noxious stings"]={3,0,1}, ["pathfinding"]={1,0,1}, ["piercing shots"]={2,0,1},
            ["point of no escape"]={3,0,1}, ["ranged weapon specialization"]={2,0,1}, ["rapid fire"]={2,26,1},
            ["rapid killing"]={2,0,1}, ["rapid recuperation"]={2,0,1}, ["raptor strike"]={3,1,1},
            ["readiness"]={2,0,1}, ["resourcefulness"]={3,0,1}, ["revive pet"]={1,10,8},
            ["savage strikes"]={3,0,1}, ["scare beast"]={1,14,8}, ["scatter shot"]={3,0,1},
            ["scorpid sting"]={2,22,8}, ["serpent sting"]={2,4,8}, ["serpent's swiftness"]={1,0,1},
            ["silencing shot"]={2,0,1}, ["snake trap"]={3,68,4}, ["sniper training"]={3,0,1},
            ["spirit bond"]={1,0,8}, ["steady shot"]={2,50,1}, ["surefooted"]={3,0,1},
            ["survival instincts"]={3,0,1}, ["survival tactics"]={3,0,1}, ["survivalist"]={3,0,1},
            ["t.n.t."]={3,0,1}, ["tame beast"]={1,10,8}, ["the beast within"]={1,0,1}, ["thick hide"]={1,0,1},
            ["thrill of the hunt"]={3,0,1}, ["track beasts"]={3,1,1}, ["track demons"]={3,32,1},
            ["track dragonkin"]={3,50,1}, ["track elementals"]={3,26,1}, ["track giants"]={3,40,1},
            ["track hidden"]={3,24,1}, ["track humanoids"]={3,10,1}, ["track undead"]={3,18,1},
            ["tranquilizing shot"]={2,60,8}, ["trap launcher: explosive trap"]={3,77,4},
            ["trap mastery"]={3,0,1}, ["trueshot aura"]={2,0,64}, ["unleashed fury"]={1,0,1},
            ["viper sting"]={2,36,8}, ["volley"]={2,40,64}, ["wild quiver"]={2,0,1}, ["wing clip"]={3,12,1},
            ["wyvern sting"]={3,0,8},
        },
    },
    ROGUE = {
        specs = { "Assassination", "Combat", "Subtlety" },
        spells = {
            ["adrenaline rush"]={2,0,1}, ["aggression"]={2,0,1}, ["ambush"]={1,18,1}, ["backstab"]={2,4,1},
            ["blade flurry"]={2,0,1}, ["blade twisting"]={2,0,1}, ["blind"]={3,34,1},
            ["blood spatter"]={1,0,1}, ["camouflage"]={3,0,1}, ["cheap shot"]={1,26,1},
            ["cheat death"]={3,0,1}, ["cloak of shadows"]={3,66,1}, ["close quarters combat"]={2,0,1},
            ["cold blood"]={1,0,1}, ["combat potency"]={2,0,1}, ["cut to the chase"]={1,0,1},
            ["deadened nerves"]={1,0,1}, ["deadliness"]={3,0,1}, ["deadly brew"]={1,0,1},
            ["deadly throw"]={1,64,1}, ["deflection"]={2,0,1}, ["detect traps"]={3,24,1},
            ["dirty deeds"]={3,0,1}, ["dirty tricks"]={3,0,1}, ["disarm trap"]={3,30,1},
            ["dismantle"]={1,20,1}, ["distract"]={3,22,1}, ["dual wield specialization"]={2,0,1},
            ["elusiveness"]={3,0,1}, ["endurance"]={2,0,1}, ["enveloping shadows"]={3,0,1},
            ["envenom"]={1,62,8}, ["evasion"]={2,8,1}, ["eviscerate"]={1,1,1}, ["expose armor"]={1,14,1},
            ["fan of knives"]={2,80,1}, ["feint"]={2,16,1}, ["filthy tricks"]={3,0,1},
            ["find weakness"]={1,0,1}, ["fleet footed"]={1,0,1}, ["focused attacks"]={1,0,1},
            ["garrote"]={1,14,1}, ["ghostly strike"]={3,0,1}, ["gouge"]={2,6,1}, ["hack and slash"]={2,0,1},
            ["heightened senses"]={3,0,1}, ["hemorrhage"]={3,0,1}, ["honor among thieves"]={3,0,1},
            ["hunger for blood"]={1,0,1}, ["improved ambush"]={3,0,1}, ["improved eviscerate"]={1,0,1},
            ["improved expose armor"]={1,0,1}, ["improved gouge"]={2,0,1}, ["improved kick"]={2,0,1},
            ["improved kidney shot"]={1,0,1}, ["improved poisons"]={1,0,1},
            ["improved sinister strike"]={2,0,1}, ["improved slice and dice"]={2,0,1},
            ["improved sprint"]={2,0,1}, ["initiative"]={3,0,1}, ["kick"]={2,12,1}, ["kidney shot"]={1,30,1},
            ["killing spree"]={2,0,1}, ["lethality"]={1,0,1}, ["lightning reflexes"]={2,0,1},
            ["mace specialization"]={2,0,1}, ["malice"]={1,0,1}, ["master of deception"]={3,0,1},
            ["master of subtlety"]={3,0,1}, ["master poisoner"]={1,0,1}, ["murder"]={1,0,1},
            ["mutilate"]={1,0,1}, ["nerves of steel"]={2,0,1}, ["opportunity"]={3,0,1}, ["overkill"]={1,0,1},
            ["pick lock"]={0,1,1}, ["pick pocket"]={3,4,1}, ["precision"]={2,0,1}, ["premeditation"]={3,0,1},
            ["preparation"]={3,0,1}, ["prey on the weak"]={2,0,1}, ["puncturing wounds"]={2,0,1},
            ["quick recovery"]={1,0,1}, ["relentless strikes"]={3,0,1}, ["remorseless attacks"]={1,0,1},
            ["riposte"]={2,0,1}, ["rupture"]={1,20,1}, ["ruthlessness"]={1,0,1}, ["safe fall"]={3,40,1},
            ["sap"]={3,10,1}, ["savage combat"]={2,0,1}, ["seal fate"]={1,0,1}, ["serrated blades"]={3,0,1},
            ["setup"]={3,0,1}, ["shadow dance"]={3,0,1}, ["shadowstep"]={3,0,1}, ["shiv"]={2,70,1},
            ["sinister calling"]={3,0,1}, ["sinister strike"]={2,1,1}, ["slaughter from the shadows"]={3,0,1},
            ["sleight of hand"]={3,0,1}, ["slice and dice"]={1,10,1}, ["sprint"]={2,10,1}, ["stealth"]={3,1,1},
            ["surprise attacks"]={2,0,1}, ["throwing specialization"]={2,0,1},
            ["tricks of the trade"]={3,75,1}, ["turn the tables"]={1,0,1}, ["unfair advantage"]={2,0,1},
            ["vanish"]={3,22,1}, ["vigor"]={1,0,1}, ["vile poisons"]={1,0,1}, ["vitality"]={2,0,1},
            ["waylay"]={3,0,1}, ["weapon expertise"]={2,0,1},
        },
    },
    PRIEST = {
        specs = { "Discipline", "Holy", "Shadow" },
        spells = {
            ["abolish disease"]={1,32,2}, ["absolution"]={2,0,1}, ["aspiration"]={2,0,1},
            ["binding heal"]={1,64,2}, ["blessed healing"]={1,20,2}, ["blessed recovery"]={1,0,1},
            ["blessed resilience"]={1,0,1}, ["body and soul"]={1,0,1}, ["borrowed time"]={2,0,1},
            ["circle of healing"]={1,0,2}, ["cure disease"]={1,14,2}, ["darkness"]={3,0,1},
            ["desperate prayer"]={1,0,2}, ["devouring plague"]={3,20,32}, ["dispel magic"]={2,18,2},
            ["dispersion"]={3,0,1}, ["divine aegis"]={2,0,1}, ["divine fury"]={1,0,1},
            ["divine hymn"]={1,80,2}, ["divine providence"]={1,0,1}, ["divine spirit"]={2,30,2},
            ["empowered healing"]={1,0,1}, ["empowered renew"]={1,0,3}, ["enlightenment"]={2,0,1},
            ["fade"]={3,8,32}, ["fear ward"]={2,20,2}, ["flash heal"]={1,20,2}, ["focused mind"]={3,0,1},
            ["focused power"]={2,0,1}, ["focused will"]={2,0,1}, ["grace"]={2,0,1}, ["greater heal"]={1,40,2},
            ["guardian spirit"]={1,0,2}, ["heal"]={1,16,2}, ["healing focus"]={1,0,1},
            ["healing prayers"]={1,0,1}, ["holy concentration"]={1,0,1}, ["holy fire"]={1,20,2},
            ["holy nova"]={1,20,2}, ["holy reach"]={1,0,1}, ["holy specialization"]={1,0,1},
            ["hymn of hope"]={1,80,2}, ["improved devouring plague"]={3,0,1}, ["improved flash heal"]={2,0,1},
            ["improved healing"]={1,0,1}, ["improved inner fire"]={2,0,1}, ["improved mana burn"]={2,0,1},
            ["improved mind blast"]={3,0,1}, ["improved power word: fortitude"]={2,0,1},
            ["improved power word: shield"]={2,0,1}, ["improved psychic scream"]={3,0,1},
            ["improved renew"]={1,0,1}, ["improved shadow word: pain"]={3,0,1},
            ["improved shadowform"]={3,0,1}, ["improved spirit tap"]={3,0,1},
            ["improved vampiric embrace"]={3,0,1}, ["inner fire"]={2,12,2}, ["inner focus"]={2,0,1},
            ["inspiration"]={1,0,1}, ["lesser heal"]={1,1,2}, ["levitate"]={2,34,2}, ["lightwell"]={1,0,2},
            ["mana burn"]={2,24,32}, ["martyrdom"]={2,0,1}, ["mass dispel"]={2,70,2}, ["meditation"]={2,0,1},
            ["mental agility"]={2,0,1}, ["mental strength"]={2,0,1}, ["mind blast"]={3,10,32},
            ["mind control"]={3,30,32}, ["mind flay"]={3,0,32}, ["mind melt"]={3,0,1}, ["mind sear"]={3,75,32},
            ["mind soothe"]={3,20,32}, ["mind vision"]={3,22,32}, ["misery"]={3,0,1},
            ["pain and suffering"]={3,0,1}, ["pain suppression"]={2,0,2}, ["penance"]={2,0,2},
            ["power infusion"]={2,0,2}, ["power word: fortitude"]={2,1,2}, ["power word: shield"]={2,6,2},
            ["prayer of fortitude"]={2,48,2}, ["prayer of healing"]={1,30,2}, ["prayer of mending"]={1,68,2},
            ["prayer of shadow protection"]={3,56,2}, ["prayer of spirit"]={2,60,2},
            ["psychic horror"]={3,0,32}, ["psychic scream"]={3,14,32}, ["rapture"]={2,0,1},
            ["reflective shield"]={2,0,1}, ["renew"]={1,8,2}, ["renewed hope"]={2,0,1},
            ["resurrection"]={1,10,2}, ["searing light"]={1,0,1}, ["serendipity"]={1,0,1},
            ["shackle undead"]={2,20,2}, ["shadow affinity"]={3,0,1}, ["shadow focus"]={3,0,1},
            ["shadow power"]={3,0,1}, ["shadow protection"]={3,30,32}, ["shadow reach"]={3,0,1},
            ["shadow weaving"]={3,0,1}, ["shadow word: death"]={3,62,32}, ["shadow word: pain"]={3,4,32},
            ["shadowfiend"]={3,66,32}, ["shadowform"]={3,0,33}, ["silence"]={3,0,32},
            ["silent resolve"]={2,0,1}, ["smite"]={1,1,2}, ["soul warding"]={2,0,1}, ["spell warding"]={1,0,1},
            ["spirit of redemption"]={1,0,1}, ["spirit tap"]={3,0,1}, ["spiritual guidance"]={1,0,1},
            ["spiritual healing"]={1,0,1}, ["surge of light"]={1,0,1}, ["test of faith"]={1,0,1},
            ["twin disciplines"]={2,0,1}, ["twisted faith"]={3,0,1}, ["unbreakable will"]={2,0,1},
            ["vampiric embrace"]={3,0,32}, ["vampiric touch"]={3,0,32}, ["veiled shadows"]={3,0,1},
        },
    },
    DEATHKNIGHT = {
        specs = { "Blood", "Frost", "Unholy" },
        spells = {
            ["abomination's might"]={1,0,1}, ["acclimation"]={2,0,1}, ["acherus deathcharger"]={3,55,32},
            ["annihilation"]={2,0,1}, ["anti-magic shell"]={3,68,32}, ["anti-magic zone"]={3,0,32},
            ["anticipation"]={3,0,1}, ["army of the dead"]={3,80,32}, ["black ice"]={2,0,1},
            ["blade barrier"]={1,0,1}, ["bladed armor"]={1,0,1}, ["blood boil"]={1,58,32},
            ["blood gorged"]={1,0,1}, ["blood of the north"]={2,0,32}, ["blood plague"]={3,1,32},
            ["blood presence"]={1,55,1}, ["blood strike"]={1,55,1}, ["blood tap"]={1,64,1},
            ["blood-caked blade"]={3,0,1}, ["bloodworms"]={1,0,8}, ["bloody strikes"]={1,0,1},
            ["bloody vengeance"]={1,0,1}, ["bone shield"]={3,0,8}, ["butchery"]={1,0,1},
            ["chains of ice"]={2,58,16}, ["chilblains"]={2,0,1}, ["chill of the grave"]={2,0,1},
            ["corpse explosion"]={3,0,32}, ["crypt fever"]={3,0,8}, ["dancing rune weapon"]={1,0,1},
            ["dark command"]={1,65,1}, ["dark conviction"]={1,0,1}, ["death and decay"]={3,60,32},
            ["death coil"]={1,55,32}, ["death gate"]={3,55,32}, ["death grip"]={3,55,1},
            ["death pact"]={1,66,32}, ["death rune mastery"]={1,0,32}, ["death strike"]={3,56,1},
            ["deathchill"]={2,0,16}, ["desecration"]={3,0,32}, ["desolation"]={3,0,32}, ["dirge"]={3,0,1},
            ["ebon plaguebringer"]={3,0,1}, ["empower rune weapon"]={2,75,0}, ["endless winter"]={2,0,1},
            ["epidemic"]={3,0,1}, ["forceful deflection"]={1,55,1}, ["frigid dreadplate"]={2,0,16},
            ["frost fever"]={2,0,16}, ["frost presence"]={2,57,16}, ["frost strike"]={2,0,16},
            ["frozen rune weapon"]={2,55,16}, ["ghoul frenzy"]={3,0,8}, ["glacier rot"]={2,0,1},
            ["guile of gorefiend"]={2,0,1}, ["heart strike"]={1,0,1}, ["horn of winter"]={2,65,1},
            ["howling blast"]={2,0,16}, ["hungering cold"]={2,0,16}, ["icebound fortitude"]={2,62,1},
            ["icy reach"]={2,0,1}, ["icy talons"]={2,0,16}, ["icy touch"]={2,55,16},
            ["improved blood presence"]={1,0,1}, ["improved death strike"]={1,0,1},
            ["improved frost presence"]={2,0,1}, ["improved icy talons"]={2,0,16},
            ["improved icy touch"]={2,0,16}, ["improved rune tap"]={1,0,32},
            ["improved unholy presence"]={3,0,1}, ["impurity"]={3,0,1}, ["killing machine"]={2,0,1},
            ["lichborne"]={2,0,32}, ["magic suppression"]={3,0,32}, ["mark of blood"]={1,0,32},
            ["master of ghouls"]={3,0,1}, ["merciless combat"]={2,0,1}, ["might of mograine"]={1,0,1},
            ["mind freeze"]={2,57,16}, ["morbidity"]={3,0,1}, ["necrosis"]={3,0,33},
            ["nerves of cold steel"]={2,0,1}, ["night of the dead"]={3,0,1}, ["obliterate"]={2,0,1},
            ["on a pale horse"]={3,0,1}, ["outbreak"]={3,0,1}, ["path of frost"]={2,61,1},
            ["pestilence"]={1,56,32}, ["plague strike"]={3,55,1}, ["rage of rivendare"]={3,0,1},
            ["raise ally"]={3,72,1}, ["raise dead"]={3,56,1}, ["ravenous dead"]={3,0,1}, ["reaping"]={3,0,1},
            ["rime"]={2,0,1}, ["rune of cinderglacier"]={0,55,1}, ["rune of lichbane"]={0,60,1},
            ["rune of razorice"]={0,55,1}, ["rune of spellbreaking"]={0,57,1},
            ["rune of spellshattering"]={0,57,1}, ["rune of swordbreaking"]={0,63,1},
            ["rune of swordshattering"]={0,63,1}, ["rune of the fallen crusader"]={0,70,1},
            ["rune of the nerubian carapace"]={0,40,1}, ["rune of the stoneskin gargoyle"]={0,70,1},
            ["rune strike"]={2,67,1}, ["rune tap"]={1,0,32}, ["runeforging"]={0,55,1},
            ["runic power mastery"]={2,0,1}, ["scent of blood"]={1,0,1}, ["scourge strike"]={3,0,1},
            ["spell deflection"]={1,0,1}, ["strangulate"]={1,59,32}, ["subversion"]={1,0,1},
            ["sudden doom"]={1,0,1}, ["summon gargoyle"]={3,0,32}, ["threat of thassarian"]={2,0,1},
            ["toughness"]={2,0,1}, ["tundra stalker"]={2,0,16}, ["two-handed weapon specialization"]={1,0,1},
            ["unbreakable armor"]={2,0,1}, ["unholy blight"]={3,0,32}, ["unholy command"]={3,0,1},
            ["unholy frenzy"]={1,0,1}, ["unholy presence"]={3,70,32}, ["vampiric blood"]={1,0,1},
            ["vendetta"]={1,0,32}, ["veteran of the third war"]={1,0,1}, ["vicious strikes"]={3,0,1},
            ["virulence"]={3,0,1}, ["wandering plague"]={3,0,40}, ["will of the necropolis"]={1,0,1},
        },
    },
    SHAMAN = {
        specs = { "Elemental", "Enhancement", "Restoration" },
        spells = {
            ["ancestral awakening"]={3,0,1}, ["ancestral healing"]={3,0,1}, ["ancestral knowledge"]={2,0,1},
            ["ancestral spirit"]={3,12,8}, ["anticipation"]={2,0,1}, ["astral recall"]={2,30,8},
            ["astral shift"]={1,0,1}, ["blessing of the eternals"]={3,0,1}, ["bloodlust"]={2,70,8},
            ["booming echoes"]={1,0,1}, ["call of flame"]={1,0,1}, ["call of the ancestors"]={1,40,0},
            ["call of the elements"]={1,30,0}, ["call of the spirits"]={1,50,0}, ["call of thunder"]={1,0,1},
            ["chain heal"]={3,40,8}, ["chain lightning"]={1,32,8}, ["cleanse spirit"]={3,0,8},
            ["cleansing totem"]={3,38,1}, ["concussion"]={1,0,1}, ["convection"]={1,0,1},
            ["cure toxins"]={3,16,8}, ["dual wield"]={2,0,1}, ["dual wield specialization"]={2,0,1},
            ["earth elemental totem"]={2,66,1}, ["earth shield"]={3,0,8}, ["earth shock"]={1,4,8},
            ["earth's grasp"]={2,0,1}, ["earthbind totem"]={1,6,1}, ["earthen power"]={2,0,1},
            ["earthliving weapon"]={3,30,8}, ["elemental devastation"]={1,0,1}, ["elemental focus"]={1,0,1},
            ["elemental fury"]={1,0,1}, ["elemental mastery"]={1,0,8}, ["elemental oath"]={1,0,1},
            ["elemental precision"]={1,0,1}, ["elemental reach"]={1,0,1}, ["elemental warding"]={1,0,1},
            ["elemental weapons"]={2,0,1}, ["enhancing totems"]={2,0,1}, ["eye of the storm"]={1,0,1},
            ["far sight"]={2,26,8}, ["feral spirit"]={2,0,8}, ["fire elemental totem"]={1,68,1},
            ["fire nova"]={1,12,4}, ["fire resistance totem"]={2,28,17}, ["flame shock"]={1,10,4},
            ["flametongue totem"]={2,28,1}, ["flametongue weapon"]={2,10,4}, ["flurry"]={2,0,1},
            ["focused mind"]={3,0,1}, ["frost resistance totem"]={2,24,1}, ["frost shock"]={1,20,16},
            ["frostbrand weapon"]={2,20,16}, ["frozen power"]={2,0,1}, ["ghost wolf"]={2,16,8},
            ["grounding totem"]={2,30,1}, ["guardian totems"]={2,0,1}, ["healing focus"]={3,0,1},
            ["healing grace"]={3,0,1}, ["healing stream totem"]={3,20,17}, ["healing wave"]={3,1,8},
            ["healing way"]={3,0,1}, ["heroism"]={2,70,8}, ["hex"]={1,80,8}, ["improved chain heal"]={3,0,1},
            ["improved earth shield"]={3,0,1}, ["improved fire nova"]={1,0,1}, ["improved ghost wolf"]={2,0,1},
            ["improved healing wave"]={3,0,1}, ["improved reincarnation"]={3,0,1},
            ["improved shields"]={2,0,1}, ["improved stormstrike"]={2,0,1}, ["improved water shield"]={3,0,1},
            ["improved windfury totem"]={2,0,1}, ["lava burst"]={1,75,4}, ["lava flows"]={1,0,1},
            ["lava lash"]={2,0,4}, ["lesser healing wave"]={3,20,8}, ["lightning bolt"]={1,1,8},
            ["lightning mastery"]={1,0,1}, ["lightning overload"]={1,0,1}, ["lightning shield"]={2,8,8},
            ["maelstrom weapon"]={2,0,1}, ["magma totem"]={1,26,1}, ["mana spring totem"]={3,26,1},
            ["mana tide totem"]={3,0,1}, ["mental dexterity"]={2,0,1}, ["mental quickness"]={2,0,1},
            ["nature resistance totem"]={2,30,1}, ["nature's blessing"]={3,0,1}, ["nature's guardian"]={3,0,1},
            ["nature's swiftness"]={3,0,1}, ["purge"]={1,12,8}, ["purification"]={3,0,1},
            ["reincarnation"]={3,30,8}, ["restorative totems"]={3,0,1}, ["reverberation"]={1,0,1},
            ["riptide"]={3,0,8}, ["rockbiter weapon"]={2,1,8}, ["searing totem"]={1,10,1},
            ["sentry totem"]={2,34,1}, ["shamanism"]={1,0,1}, ["shamanistic focus"]={2,0,1},
            ["shamanistic rage"]={2,0,1}, ["spirit weapons"]={2,0,1}, ["static shock"]={2,0,1},
            ["stoneclaw totem"]={1,8,1}, ["stoneskin totem"]={2,4,1}, ["storm, earth and fire"]={1,0,1},
            ["stormstrike"]={2,0,1}, ["strength of earth totem"]={2,10,1}, ["thundering strikes"]={2,0,1},
            ["thunderstorm"]={1,0,8}, ["tidal focus"]={3,0,1}, ["tidal force"]={3,0,1},
            ["tidal mastery"]={3,0,1}, ["tidal waves"]={3,0,1}, ["totem of wrath"]={1,0,1},
            ["totemic focus"]={3,0,1}, ["totemic recall"]={3,30,8}, ["toughness"]={2,0,1},
            ["tremor totem"]={3,18,1}, ["unleashed rage"]={2,0,1}, ["unrelenting storm"]={1,0,1},
            ["water breathing"]={2,22,8}, ["water shield"]={3,20,8}, ["water walking"]={2,28,8},
            ["weapon mastery"]={2,0,1}, ["wind shear"]={1,16,8}, ["windfury totem"]={2,32,1},
            ["windfury weapon"]={2,30,8}, ["wrath of air totem"]={2,64,1},
        },
    },
    MAGE = {
        specs = { "Arcane", "Fire", "Frost" },
        spells = {
            ["amplify magic"]={1,18,64}, ["arcane barrage"]={1,0,64}, ["arcane blast"]={1,64,64},
            ["arcane brilliance"]={1,56,64}, ["arcane concentration"]={1,0,64}, ["arcane empowerment"]={1,0,1},
            ["arcane explosion"]={1,14,64}, ["arcane flows"]={1,0,1}, ["arcane focus"]={1,0,64},
            ["arcane fortitude"]={1,0,1}, ["arcane instability"]={1,0,1}, ["arcane intellect"]={1,1,64},
            ["arcane meditation"]={1,0,1}, ["arcane mind"]={1,0,64}, ["arcane missiles"]={1,8,64},
            ["arcane potency"]={1,0,1}, ["arcane power"]={1,0,64}, ["arcane shielding"]={1,0,1},
            ["arcane stability"]={1,0,1}, ["arcane subtlety"]={1,0,64}, ["arctic reach"]={3,0,1},
            ["arctic winds"]={3,0,1}, ["blast wave"]={2,0,4}, ["blazing speed"]={2,0,4}, ["blink"]={1,20,64},
            ["blizzard"]={3,20,16}, ["brain freeze"]={3,0,1}, ["burning determination"]={2,0,4},
            ["burning soul"]={2,0,4}, ["burnout"]={2,0,4}, ["chilled to the bone"]={3,0,1},
            ["cold as ice"]={3,0,1}, ["cold snap"]={3,0,16}, ["combustion"]={2,0,4},
            ["cone of cold"]={3,26,16}, ["conjure food"]={1,6,64}, ["conjure mana gem"]={1,28,64},
            ["conjure refreshment"]={1,75,64}, ["conjure water"]={1,4,64}, ["counterspell"]={1,24,64},
            ["critical mass"]={2,0,4}, ["dalaran brilliance"]={1,80,64}, ["dalaran intellect"]={1,80,64},
            ["dampen magic"]={1,12,64}, ["deep freeze"]={3,0,16}, ["dragon's breath"]={2,0,4},
            ["empowered fire"]={2,0,4}, ["empowered frostbolt"]={3,0,16}, ["enduring winter"]={3,0,1},
            ["evocation"]={1,20,64}, ["fiery payback"]={2,0,1}, ["fingers of frost"]={3,0,1},
            ["fire blast"]={2,6,4}, ["fire power"]={2,0,4}, ["fire ward"]={2,20,4}, ["fireball"]={2,1,4},
            ["firestarter"]={2,0,4}, ["flame throwing"]={2,0,4}, ["flamestrike"]={2,16,4},
            ["focus magic"]={1,0,64}, ["frost armor"]={3,1,16}, ["frost channeling"]={3,0,16},
            ["frost nova"]={3,10,16}, ["frost ward"]={3,22,16}, ["frost warding"]={3,0,1},
            ["frostbite"]={3,0,16}, ["frostbolt"]={3,4,16}, ["frostfire bolt"]={2,75,20},
            ["frozen core"]={3,0,1}, ["hot streak"]={2,0,4}, ["ice armor"]={3,30,16}, ["ice barrier"]={3,0,16},
            ["ice block"]={3,30,16}, ["ice floes"]={3,0,1}, ["ice lance"]={3,66,16}, ["ice shards"]={3,0,16},
            ["icy veins"]={3,0,16}, ["ignite"]={2,0,5}, ["impact"]={2,0,4}, ["improved blink"]={1,0,1},
            ["improved blizzard"]={3,0,1}, ["improved cone of cold"]={3,0,1},
            ["improved counterspell"]={1,0,1}, ["improved fire blast"]={2,0,1}, ["improved fireball"]={2,0,4},
            ["improved frostbolt"]={3,0,1}, ["improved scorch"]={2,0,1}, ["incanter's absorption"]={1,0,1},
            ["incineration"]={2,0,1}, ["invisibility"]={1,68,64}, ["living bomb"]={2,0,4},
            ["mage armor"]={1,34,64}, ["magic absorption"]={1,0,64}, ["magic attunement"]={1,0,1},
            ["mana shield"]={1,20,64}, ["master of elements"]={2,0,4}, ["mind mastery"]={1,0,1},
            ["mirror image"]={1,80,64}, ["missile barrage"]={1,0,1}, ["molten armor"]={2,62,4},
            ["molten fury"]={2,0,1}, ["molten shields"]={2,0,1}, ["netherwind presence"]={1,0,1},
            ["permafrost"]={3,0,1}, ["piercing ice"]={3,0,16}, ["playing with fire"]={2,0,4},
            ["polymorph"]={1,8,64}, ["portal: dalaran"]={1,74,64}, ["portal: darnassus"]={1,50,64},
            ["portal: exodar"]={1,40,64}, ["portal: ironforge"]={1,40,64}, ["portal: orgrimmar"]={1,40,64},
            ["portal: shattrath"]={1,65,64}, ["portal: silvermoon"]={1,40,64}, ["portal: stonard"]={1,35,64},
            ["portal: stormwind"]={1,40,64}, ["portal: theramore"]={1,35,64},
            ["portal: thunder bluff"]={1,50,64}, ["portal: undercity"]={1,40,64}, ["precision"]={3,0,64},
            ["presence of mind"]={1,0,1}, ["prismatic cloak"]={1,0,1}, ["pyroblast"]={2,0,4},
            ["pyromaniac"]={2,0,4}, ["remove curse"]={1,18,64}, ["ritual of refreshment"]={1,70,64},
            ["scorch"]={2,22,4}, ["shatter"]={3,0,1}, ["shattered barrier"]={3,0,16}, ["slow"]={1,0,64},
            ["slow fall"]={1,12,64}, ["spell impact"]={1,0,1}, ["spell power"]={1,0,1},
            ["spellsteal"]={1,70,64}, ["student of the mind"]={1,0,1}, ["summon water elemental"]={3,0,16},
            ["summon water elemental (prototype)"]={3,50,16}, ["teleport: dalaran"]={1,71,64},
            ["teleport: darnassus"]={1,30,64}, ["teleport: exodar"]={1,20,64},
            ["teleport: ironforge"]={1,20,64}, ["teleport: orgrimmar"]={1,20,64},
            ["teleport: shattrath"]={1,60,64}, ["teleport: silvermoon"]={1,20,64},
            ["teleport: stonard"]={1,35,64}, ["teleport: stormwind"]={1,20,64},
            ["teleport: theramore"]={1,35,64}, ["teleport: thunder bluff"]={1,30,64},
            ["teleport: undercity"]={1,20,64}, ["torment the weak"]={1,0,64}, ["winter's chill"]={3,0,1},
            ["world in flames"]={2,0,1},
        },
    },
    WARLOCK = {
        specs = { "Affliction", "Demonology", "Destruction" },
        spells = {
            ["aftermath"]={3,0,1}, ["amplify curse"]={1,0,32}, ["backdraft"]={3,0,1}, ["backlash"]={3,0,4},
            ["bane"]={3,0,1}, ["banish"]={2,28,32}, ["cataclysm"]={3,0,1}, ["challenging howl"]={2,1,1},
            ["chaos bolt"]={3,0,4}, ["conflagrate"]={3,0,4}, ["contagion"]={1,0,1}, ["corruption"]={1,4,32},
            ["create firestone"]={2,28,4}, ["create healthstone"]={2,10,32}, ["create soulstone"]={2,18,32},
            ["create spellstone"]={2,36,32}, ["curse of agony"]={1,8,32}, ["curse of doom"]={1,60,32},
            ["curse of exhaustion"]={1,0,32}, ["curse of the elements"]={1,32,32},
            ["curse of tongues"]={1,26,32}, ["curse of weakness"]={1,4,32}, ["dark pact"]={1,0,32},
            ["death coil"]={1,42,32}, ["death's embrace"]={1,0,1}, ["decimation"]={2,0,1},
            ["demon armor"]={2,20,32}, ["demon charge"]={2,60,1}, ["demon skin"]={2,1,32},
            ["demonic aegis"]={2,0,1}, ["demonic brutality"]={2,0,1}, ["demonic circle: summon"]={2,80,32},
            ["demonic circle: teleport"]={2,80,32}, ["demonic embrace"]={2,0,1},
            ["demonic empowerment"]={2,0,32}, ["demonic immolate"]={3,0,1}, ["demonic knowledge"]={2,0,1},
            ["demonic pact"]={2,0,1}, ["demonic power"]={3,0,1}, ["demonic resilience"]={2,0,1},
            ["demonic tactics"]={2,0,1}, ["destructive reach"]={3,0,1}, ["detect invisibility"]={2,26,32},
            ["devastation"]={3,0,1}, ["drain life"]={1,14,32}, ["drain mana"]={1,24,32},
            ["drain soul"]={1,10,32}, ["dreadsteed"]={2,40,1}, ["emberstorm"]={3,0,1},
            ["empowered corruption"]={1,0,1}, ["empowered imp"]={2,0,1}, ["eradication"]={1,0,1},
            ["everlasting affliction"]={1,0,1}, ["eye of kilrogg"]={2,22,32}, ["fear"]={1,8,32},
            ["fel armor"]={2,62,32}, ["fel concentration"]={1,0,1}, ["fel domination"]={2,0,32},
            ["fel synergy"]={2,0,1}, ["fel vitality"]={2,0,1}, ["felsteed"]={2,20,1},
            ["fire and brimstone"]={3,0,1}, ["grim reach"]={1,0,1}, ["haunt"]={1,0,32},
            ["health funnel"]={2,12,32}, ["hellfire"]={3,30,4}, ["howl of terror"]={1,40,32},
            ["immolate"]={3,1,4}, ["immolation aura"]={2,60,4}, ["improved corruption"]={1,0,1},
            ["improved curse of agony"]={1,0,1}, ["improved curse of weakness"]={1,0,1},
            ["improved demonic tactics"]={2,0,1}, ["improved drain soul"]={1,0,1}, ["improved fear"]={1,0,1},
            ["improved felhunter"]={1,0,1}, ["improved health funnel"]={2,0,1},
            ["improved healthstone"]={2,0,1}, ["improved howl of terror"]={1,0,1},
            ["improved immolate"]={3,0,1}, ["improved imp"]={2,0,1}, ["improved life tap"]={1,0,1},
            ["improved sayaad"]={2,0,1}, ["improved searing pain"]={3,0,1}, ["improved shadow bolt"]={3,0,1},
            ["improved soul leech"]={3,0,1}, ["incinerate"]={3,64,4}, ["inferno"]={2,50,32},
            ["intensity"]={3,0,1}, ["life tap"]={1,6,32}, ["malediction"]={1,0,1}, ["mana feed"]={2,0,1},
            ["master conjuror"]={2,0,1}, ["master demonologist"]={2,0,32}, ["master summoner"]={2,0,1},
            ["metamorphosis"]={2,0,1}, ["molten core"]={3,0,1}, ["molten skin"]={3,0,1}, ["nemesis"]={2,0,1},
            ["nether protection"]={3,0,1}, ["nightfall"]={1,0,1}, ["pandemic"]={1,0,1}, ["pyroclasm"]={3,0,4},
            ["rain of fire"]={3,20,4}, ["ritual of doom"]={2,60,32}, ["ritual of souls"]={2,68,32},
            ["ritual of summoning"]={2,20,32}, ["ruin"]={3,0,1}, ["searing pain"]={3,18,4},
            ["seed of corruption"]={1,70,32}, ["sense demons"]={2,24,32}, ["shadow and flame"]={3,0,1},
            ["shadow bolt"]={3,1,32}, ["shadow cleave"]={2,60,32}, ["shadow embrace"]={1,0,1},
            ["shadow mastery"]={1,0,1}, ["shadow ward"]={2,32,32}, ["shadowburn"]={3,0,32},
            ["shadowflame"]={3,75,32}, ["shadowfury"]={3,0,32}, ["siphon life"]={1,0,1},
            ["soul fire"]={3,48,4}, ["soul leech"]={3,0,1}, ["soul link"]={2,0,32}, ["soul siphon"]={1,0,1},
            ["soulshatter"]={2,66,32}, ["subjugate demon"]={2,30,32}, ["summon felguard"]={2,0,32},
            ["summon felhunter"]={2,30,32}, ["summon imp"]={2,1,32}, ["summon incubus"]={2,20,32},
            ["summon succubus"]={2,20,32}, ["summon voidwalker"]={2,10,32}, ["suppression"]={1,0,1},
            ["unending breath"]={2,16,32}, ["unholy power"]={2,0,1}, ["unstable affliction"]={1,0,32},
        },
    },
    DRUID = {
        specs = { "Balance", "Feral Combat", "Restoration" },
        spells = {
            ["abolish poison"]={3,26,8}, ["aquatic form"]={2,16,1}, ["balance of power"]={1,0,1},
            ["barkskin"]={1,44,8}, ["bash"]={2,14,1}, ["bear form"]={2,10,1}, ["berserk"]={2,0,1},
            ["brambles"]={1,0,1}, ["brutal impact"]={2,0,1}, ["cat form"]={2,20,1},
            ["celestial focus"]={1,0,1}, ["challenging roar"]={2,28,1}, ["claw"]={2,20,1}, ["cower"]={2,28,1},
            ["cure poison"]={3,14,8}, ["cyclone"]={1,70,8}, ["dash"]={2,26,1}, ["demoralizing roar"]={2,10,1},
            ["dire bear form"]={2,40,1}, ["dreamstate"]={1,0,1}, ["earth and moon"]={1,0,1},
            ["eclipse"]={1,0,1}, ["empowered rejuvenation"]={3,0,1}, ["empowered touch"]={3,0,1},
            ["enrage"]={2,12,1}, ["entangling roots"]={1,8,8}, ["faerie fire"]={1,18,8},
            ["faerie fire (feral)"]={2,18,8}, ["feline grace"]={2,40,1}, ["feral aggression"]={2,0,1},
            ["feral charge"]={2,0,1}, ["feral charge - bear"]={2,20,1}, ["feral charge - cat"]={2,20,1},
            ["feral instinct"]={2,0,1}, ["feral swiftness"]={2,0,1}, ["ferocious bite"]={2,32,1},
            ["ferocity"]={2,0,1}, ["flight form"]={2,60,1}, ["force of nature"]={1,0,8},
            ["frenzied regeneration"]={2,36,1}, ["furor"]={3,0,1}, ["gale winds"]={1,0,1}, ["genesis"]={1,0,1},
            ["gift of nature"]={3,0,1}, ["gift of the earthmother"]={3,0,1}, ["gift of the wild"]={3,50,8},
            ["growl"]={2,10,1}, ["healing touch"]={3,1,8}, ["heart of the wild"]={2,0,1},
            ["hibernate"]={1,18,8}, ["hurricane"]={1,40,8}, ["improved barkskin"]={3,0,1},
            ["improved faerie fire"]={1,0,1}, ["improved insect swarm"]={1,0,1},
            ["improved leader of the pack"]={2,0,1}, ["improved mangle"]={2,0,1},
            ["improved mark of the wild"]={3,0,1}, ["improved moonfire"]={1,0,1},
            ["improved moonkin form"]={1,0,1}, ["improved rejuvenation"]={3,0,1},
            ["improved tranquility"]={3,0,1}, ["improved tree of life"]={3,0,1}, ["infected wounds"]={2,0,1},
            ["innervate"]={1,40,8}, ["insect swarm"]={1,0,8}, ["intensity"]={3,0,1},
            ["king of the jungle"]={2,0,1}, ["lacerate"]={2,66,1}, ["leader of the pack"]={2,0,1},
            ["lifebloom"]={3,64,8}, ["living seed"]={3,0,1}, ["living spirit"]={3,0,1},
            ["lunar guidance"]={1,0,1}, ["maim"]={2,62,1}, ["mangle"]={2,0,1}, ["mangle (bear)"]={2,50,1},
            ["mangle (cat)"]={2,50,1}, ["mark of the wild"]={3,1,8}, ["master shapeshifter"]={2,0,8},
            ["maul"]={2,10,1}, ["moonfire"]={1,4,64}, ["moonfury"]={1,0,1}, ["moonglow"]={1,0,1},
            ["moonkin form"]={1,0,1}, ["natural perfection"]={3,0,1}, ["natural reaction"]={2,0,1},
            ["natural shapeshifter"]={3,0,1}, ["naturalist"]={3,0,1}, ["nature's bounty"]={3,0,1},
            ["nature's focus"]={3,0,1}, ["nature's grace"]={1,0,1}, ["nature's grasp"]={1,10,8},
            ["nature's majesty"]={1,0,1}, ["nature's reach"]={1,0,1}, ["nature's splendor"]={1,0,1},
            ["nature's swiftness"]={3,0,1}, ["nourish"]={3,80,8}, ["nurturing instinct"]={2,0,1},
            ["omen of clarity"]={3,0,8}, ["owlkin frenzy"]={1,0,1}, ["pounce"]={2,36,1},
            ["predatory instincts"]={2,0,1}, ["predatory strikes"]={2,0,1}, ["primal fury"]={2,0,1},
            ["primal gore"]={2,0,1}, ["primal precision"]={2,0,1}, ["primal tenacity"]={2,0,1},
            ["protector of the pack"]={2,0,1}, ["prowl"]={2,20,1}, ["rake"]={2,24,1}, ["ravage"]={2,32,1},
            ["rebirth"]={3,20,8}, ["regrowth"]={3,12,8}, ["rejuvenation"]={3,4,8}, ["remove curse"]={3,24,64},
            ["rend and tear"]={2,0,1}, ["revitalize"]={3,0,1}, ["revive"]={3,12,8}, ["rip"]={2,20,1},
            ["savage defense"]={2,40,1}, ["savage fury"]={2,0,1}, ["savage roar"]={2,75,1},
            ["sharpened claws"]={2,0,1}, ["shred"]={2,22,1}, ["shredding attacks"]={2,0,1},
            ["soothe animal"]={1,22,8}, ["starfall"]={1,0,64}, ["starfire"]={1,20,64},
            ["starlight wrath"]={1,0,1}, ["subtlety"]={3,0,1}, ["survival instincts"]={2,0,1},
            ["survival of the fittest"]={2,0,1}, ["swift flight form"]={2,70,1}, ["swiftmend"]={3,0,8},
            ["swipe (bear)"]={2,16,1}, ["swipe (cat)"]={2,71,1}, ["teleport: moonglade"]={1,10,64},
            ["thick hide"]={2,0,1}, ["thorns"]={1,6,8}, ["tiger's fury"]={2,24,1},
            ["track humanoids"]={2,32,1}, ["tranquil spirit"]={3,0,1}, ["tranquility"]={3,30,8},
            ["travel form"]={2,16,1}, ["tree of life"]={3,0,1}, ["typhoon"]={1,0,8}, ["vengeance"]={1,0,1},
            ["wild growth"]={3,0,8}, ["wrath"]={1,1,8}, ["wrath of cenarius"]={1,0,1},
        },
    },
}
-- END GENERATED SPELLTABS

NS.spellHideUntil = {}      -- lower(name) -> GetTime() until which that bot's whispers are the "spells" reply
NS.botSpellState = {}       -- lower(name) -> array of { id, name, link, icon }
NS.botSpellRaw = {}         -- lower(name) -> first non-spell lines of the reply (shown if nothing parsed)
NS.spellAwaiting = {}       -- lower(name) -> { list, seen, raw, timer }
NS.botSpellFrames = {}
NS.SPELL_COLS, NS.SPELL_ROWS, NS.SPELL_CELL = 8, 5, 38

--- The spell lists persist (AltBot_SavedVars.spellCache): the window opens straight from them
--- and the fetch started at the same moment refreshes them. Icons are not stored (re-read from
--- the client by spell id); the list of a wild-class bot is wiped at logout like its other caches.
NS.SaveSpellCache = function(key, list)
    if not AltBot_SavedVars then return end
    AltBot_SavedVars.spellCache = AltBot_SavedVars.spellCache or {}
    local out = {}
    for i, sp in ipairs(list) do out[i] = { id = sp.id, name = sp.name, link = sp.link } end
    AltBot_SavedVars.spellCache[key] = out
end

NS.LoadSpellCache = function(key)
    local saved = AltBot_SavedVars and AltBot_SavedVars.spellCache and AltBot_SavedVars.spellCache[key]
    if not saved then return end
    local list = {}
    for i, sp in ipairs(saved) do
        local _, _, icon = GetSpellInfo(sp.id)
        list[i] = { id = sp.id, name = sp.name, link = sp.link, icon = icon }
    end
    NS.botSpellState[key] = list
end

--- Whether the bot knows a spell (by lowercase English name): from its spell list - the saved one
--- or, once per session, one fetched now. nil = not known yet.
NS.BotKnowsSpell = function(entry, lowerName)
    local key = strlower(entry.name)
    if not NS.botSpellState[key] then NS.LoadSpellCache(key) end
    local list = NS.botSpellState[key]
    if not list then
        if not entry.spellsAsked then
            entry.spellsAsked = true
            NS.FetchBotSpells(entry.name)
        end
        return nil
    end
    for _, sp in ipairs(list) do
        if strlower(sp.name) == lowerName then return true end
    end
    return false
end

-- Per-bot tracking (per explicit user direction it lives in the STRATEGY window, the bot's own or
-- the group's): ONE of "herb" / "ore" / none, like a radio group (a bot can have only one tracking
-- on, so nothing ever has to alternate). AltBot_SavedVars.trackFlags[key] = "herb" | "ore" | nil.
NS.TRACK_KINDS = { { value = "none", name = "None" }, { value = "herb", name = "Herb" }, { value = "ore", name = "Ore" } }

NS.GetTrackKind = function(key)
    local rec = AltBot_SavedVars and AltBot_SavedVars.trackFlags and AltBot_SavedVars.trackFlags[key]
    if type(rec) == "table" then   -- an older save: two flags
        return (rec.herb and "herb") or (rec.ore and "ore") or "none"
    end
    return rec or "none"
end

NS.SetTrackKind = function(key, kind)
    if not AltBot_SavedVars then return end
    AltBot_SavedVars.trackFlags = AltBot_SavedVars.trackFlags or {}
    AltBot_SavedVars.trackFlags[key] = (kind ~= "none") and kind or nil
end

--- Casts the chosen tracking (Find Herbs / Find Minerals) on a bot that knows the spell - once; again
--- only after a death, a new choice or a new raid. "None" does nothing (it does not cancel).
NS.TRACKING = { herb = { spell = "find herbs", cmd = "cast Find Herbs" },
    ore = { spell = "find minerals", cmd = "cast Find Minerals" } }
NS.ApplyTracking = function(entry)
    if entry.wasDead then return end
    local kind = NS.GetTrackKind(strlower(entry.name))
    local def = NS.TRACKING[kind]
    if not def or entry.trackedKind == kind then return end
    if NS.BotKnowsSpell(entry, def.spell) ~= true then return end
    entry.trackedKind = kind
    SendBotCommand(entry.name, def.cmd)
end

--- When the raid has just been formed (ApplyMode finished): everybody gets his tracking.
NS.ApplyTrackingAll = function()
    for _, key in ipairs(NS.rosterOrder) do
        local entry = NS.bots[key]
        if entry then
            entry.trackedKind = nil
            NS.ApplyTracking(entry)
        end
    end
end

NS.FetchBotSpells = function(botName)
    NS.spellAwaiting[strlower(botName)] = { list = {}, seen = {}, raw = {}, timer = 0 }
    NS.spellHideUntil[strlower(botName)] = GetTime() + NS.STATS_TIMEOUT + 1
    SendBotCommand(botName, "spells")
end

NS.spellWatcher = CreateFrame("Frame")
NS.spellWatcher:RegisterEvent("CHAT_MSG_WHISPER")
NS.spellWatcher:SetScript("OnEvent", function(self, event, msg, sender)
    local key = strlower(sender or "")
    local c = NS.spellAwaiting[key]
    if not c then return end
    local found = false
    for idText, name in msg:gmatch("|Hspell:(%d+)[^|]*|h%[(.-)%]|h") do
        found = true
        local id = tonumber(idText) or 0
        if not c.seen[id] then
            c.seen[id] = true
            local _, _, icon = GetSpellInfo(id)
            c.list[#c.list + 1] = { id = id, name = name, icon = icon,
                link = msg:match("(|c%x+|Hspell:" .. idText .. "[^|]*|h%[.-%]|h|r)") }
        end
    end
    if found then
        c.timer = 0
    elseif #c.raw < 3 then
        c.raw[#c.raw + 1] = NS.CleanEscapes(msg)
    end
    NS.blockedBotNames[key] = true
    NS.spellHideUntil[key] = GetTime() + NS.STATS_TIMEOUT + 1   -- keep hiding while the list streams in
    NS.After(NS.STATS_TIMEOUT, function() NS.blockedBotNames[key] = nil end)
end)

NS.spellTicker = CreateFrame("Frame")
NS.spellTicker:SetScript("OnUpdate", function(self, dt)
    local done
    for key, c in pairs(NS.spellAwaiting) do
        c.timer = c.timer + dt
        if c.timer >= NS.STATS_TIMEOUT then
            done = done or {}
            done[#done + 1] = key
        end
    end
    for _, key in ipairs(done or {}) do   -- outside the traversal
        local c = NS.spellAwaiting[key]
        NS.spellAwaiting[key] = nil
        if #c.list > 0 then
            NS.botSpellState[key] = c.list
            NS.SaveSpellCache(key, c.list)
            local e = NS.bots[key]
            if e then NS.ApplyTracking(e) end   -- the list was what the tracking was waiting for
        end
        NS.botSpellRaw[key] = c.raw
        NS.PaintSpellbook(key)
    end
end)

--- Makes/updates the macro for one spell of one bot and puts it on the cursor.
NS.MakeSpellMacro = function(botName, spell)
    -- "<full bot name>:<spell>" within the 16 character macro name limit: it is the SPELL part
    -- that gets cut (on a UTF-8 character boundary), never the bot's name.
    local mname = botName .. ":" .. spell.name
    if #mname > 16 then
        local cut = 16
        while cut > 1 and mname:byte(cut + 1) and mname:byte(cut + 1) >= 128 and mname:byte(cut + 1) < 192 do cut = cut - 1 end
        mname = strsub(mname, 1, cut)
    end
    local body = "/w " .. botName .. " cast " .. spell.name
    -- CreateMacro/EditMacro take an INDEX into the macro icon list, not a texture: find the
    -- spell's own icon in it, else the first (question mark) icon.
    local icon = 1
    local want = strlower(NS.SpellIcon(spell):match("([^\\]+)$") or "")
    if want and want ~= "" then
        for i = 1, GetNumMacroIcons() do
            local tex = GetMacroIconInfo(i)
            if tex and strlower(tex:match("([^\\]+)$") or "") == want then icon = i break end
        end
    end
    local idx
    local ok, err = pcall(function()
        idx = GetMacroIndexByName(mname)
        if idx and idx > 0 then
            EditMacro(idx, mname, icon, body)
        else
            idx = CreateMacro(mname, icon, body, nil)
        end
    end)
    if ok and idx and idx > 0 then
        PickupMacro(idx)
        Print("Macro '" .. mname .. "' is on the cursor - drop it on an action bar.", "spellbook")
    else
        Print("Could not create the macro (" .. tostring(err or "macro list full?") .. ").", "spellbook")
    end
end

NS.SPELL_ROW_H = 24
-- Profession spells are recognised BY NAME, in English only (the server sends the spell names
-- in English; per explicit user direction no Russian here). Exact names plus recipe prefixes;
-- the list is kept short and extended by hand when something professional shows up in "Spells".
NS.PROFESSION_NAMES = {}
for _, n in ipairs({
    -- professions
    "alchemy", "blacksmithing", "enchanting", "engineering", "herbalism", "inscription", "jewelcrafting",
    "leatherworking", "mining", "skinning", "tailoring", "cooking", "first aid", "fishing",
    -- tracking / gathering / processing
    "find herbs", "find minerals", "find fish", "herb gathering", "milling", "prospecting", "disenchant",
    "smelting", "basic campfire",
}) do
    NS.PROFESSION_NAMES[n] = true
end
NS.PROFESSION_PREFIXES = { "enchant ", "transmute", "smelt " }

NS.IsProfessionName = function(name)
    if not name then return false end
    local lower = strlower(name)
    if NS.PROFESSION_NAMES[lower] then return true end
    for _, prefix in ipairs(NS.PROFESSION_PREFIXES) do
        if strsub(lower, 1, #prefix) == prefix then return true end
    end
    return false
end

-- The skills window shows a profession with its own icon, not the icon of the spell that
-- teaches/starts it (Engineering: the golden cog, not the spell's hammer).
NS.PROFESSION_ICONS = {
    ["alchemy"] = "Trade_Alchemy", ["blacksmithing"] = "Trade_BlackSmithing", ["enchanting"] = "Trade_Engraving",
    ["engineering"] = "Trade_Engineering", ["herbalism"] = "Trade_Herbalism",
    ["inscription"] = "INV_Inscription_Tradeskill01", ["jewelcrafting"] = "INV_Misc_Gem_01",
    ["leatherworking"] = "Trade_LeatherWorking", ["mining"] = "Trade_Mining",
    ["skinning"] = "INV_Misc_Pelt_Wolf_01", ["tailoring"] = "Trade_Tailoring",
    ["cooking"] = "INV_Misc_Food_15", ["first aid"] = "Spell_Holy_SealOfSalvation", ["fishing"] = "Trade_Fishing",
}

--- The icon texture to show for a listed spell.
NS.SpellIcon = function(spell)
    local own = NS.PROFESSION_ICONS[strlower(spell.name)]
    if own then return "Interface\\Icons\\" .. own end
    return spell.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

NS.IsProfessionSpell = function(spell)
    return NS.IsProfessionName(spell.name)
end

-- "Other": spells that are neither class spells nor professions, recognised BY NAME (English).
-- Professions are everything that is not in the downloaded class tables and not caught here,
-- per explicit user direction - so this list is what keeps racials, auto attack, riding and the
-- like out of "Professions"; extend it by hand when something lands in the wrong group.
NS.OTHER_NAMES = {}
for _, n in ipairs({
    "auto attack", "attack", "attacking", "shoot", "activate primary spec", "activate secondary spec",
    -- engineering pets/toys that are not recipes
    "arcanite dragonling", "battle chicken", "mechanical dragonling", "mithril mechanical dragonling", "summon goblin bomb", "summon friend",
    -- racials
    "blood fury", "berserking", "arcane torrent", "war stomp", "cannibalize", "will of the forsaken",
    "shadowmeld", "quickness", "stoneform", "escape artist", "gift of the naaru", "every man for himself",
    "perception", "endurance", "find treasure", "heroic presence", "expansive mind", "mace specialization",
    "axe specialization", "sword specialization", "bow specialization", "gun specialization",
    "viciousness", "diplomacy", "regeneration", "nature resistance", "frost resistance", "shadow resistance",
    "fire resistance", "arcane affinity", "command", "cultivation", "toughness", "mace specialization",
    -- riding / flying / misc skills
    "apprentice riding", "journeyman riding", "expert riding", "artisan riding", "cold weather flying",
    "flight master's license", "master riding", "riding",
    -- languages
    "language common", "language orcish", "language darnassian", "language dwarvish", "language gnomish",
    "language draenei", "language taurahe", "language troll", "language forsaken", "language thalassian",
    "language gutterspeak", "language demonic", "language titan", "language draconic", "language kalimag",
    "language old tongue", "language zandali",
    -- passive weapon / armor proficiencies
    "dagger", "fist weapons", "one-handed axes", "one-handed maces", "one-handed swords", "two-handed axes",
    "two-handed maces", "two-handed swords", "polearms", "staves", "thrown", "bows", "crossbows", "guns", "wands",
    "cloth", "leather", "mail", "plate mail", "shield", "block", "parry", "dodge", "dual wield",
}) do
    NS.OTHER_NAMES[n] = true
end

NS.IsOtherSpell = function(spell)
    local lower = strlower(spell.name)
    return NS.OTHER_NAMES[lower] == true or lower:find(" riding$") ~= nil or lower:find("^language ") ~= nil
end

NS.GetSpellFrame = function(botName)
    local key = strlower(botName)
    local f = NS.botSpellFrames[key]
    if f then return f end
    f = CreateFrame("Frame", "AltBotSpells_" .. key, UIParent)
    f.botName = botName
    f:SetSize(360, 460)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    NS.RememberWindowPosition(f, "spells", botName)
    f:SetScript("OnMouseDown", function(self) self:Raise() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0, 0, 0, 1)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", f, "TOP", 0, -16)
    f.title:SetText(botName .. "'s Spellbook")
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- A scrolling table: icon | spell link, one group after another.
    f.scroll = CreateFrame("ScrollFrame", "AltBotSpellScroll_" .. key, f, "UIPanelScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -38)   -- right under the title bar
    f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 18)
    f.content = CreateFrame("Frame", nil, f.scroll)
    f.content:SetSize(300, 10)
    f.scroll:SetScrollChild(f.content)
    f.rows = {}

    f:Hide()
    NS.botSpellFrames[key] = f
    return f
end

--- One table row (created on demand and reused): icon + text; a header row has no icon.
NS.GetSpellRow = function(f, i)
    local row = f.rows[i]
    if row then return row end
    local h = NS.SPELL_ROW_H
    row = CreateFrame("Button", nil, f.content)
    row:SetSize(300, h)
    row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -(i - 1) * h)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(h - 4, h - 4)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.text:SetJustifyH("LEFT")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    hl:SetBlendMode("ADD")
    row.hl = hl
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnEnter", function(self)
        if not self.spell then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.spell.link then GameTooltip:SetHyperlink(self.spell.link) else GameTooltip:SetText(self.spell.name) end
        GameTooltip:AddLine("Click: cast. Right click: make a macro.", 0.6, 0.8, 1)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self, button)
        if not self.spell then return end
        if IsShiftKeyDown() then
            NS.InsertLinkIntoChat(self.spell.link)
            return
        end
        if button == "RightButton" then
            NS.MakeSpellMacro(f.botName, self.spell)   -- no menu: right click makes the macro right away
        else
            SendBotCommand(f.botName, "cast " .. self.spell.name)
        end
    end)
    f.rows[i] = row
    return row
end

NS.PaintSpellbook = function(key)
    local f = NS.botSpellFrames[key]
    if not f then return end
    local list = NS.botSpellState[key] or {}

    -- Five groups, each sorted alphabetically (per explicit user direction): the class's three
    -- talent trees (from the generated Wowhead table NS.spellTabs, matched by English spell
    -- name), Professions = whatever is NOT in that class table, and Other = our own filter of
    -- non-profession names (NS.IsOtherSpell) plus class spells outside the trees.
    local entry = NS.bots[key]
    local classTab = NS.spellTabs and entry and entry.class and NS.spellTabs[entry.class]
    local specNames = classTab and classTab.specs or { "Specialization 1", "Specialization 2", "Specialization 3" }
    local groups = {
        { header = specNames[1], spells = {} }, { header = specNames[2], spells = {} },
        { header = specNames[3], spells = {} }, { header = "Professions", spells = {} },
        { header = "Other", spells = {} },
    }
    for _, sp in ipairs(list) do
        local info = classTab and classTab.spells[strlower(sp.name)]   -- { tree, level, schools }
        local idx = info and info[1]
        if idx and idx >= 1 and idx <= 3 then
            local g = groups[idx].spells
            g[#g + 1] = sp
        elseif idx == 0 or NS.IsOtherSpell(sp) then
            -- a class spell outside the trees, or one of our "certainly not a profession" names
            local g = groups[5].spells
            g[#g + 1] = sp
        else
            -- not in the class table (so not a class spell): a profession
            local g = groups[4].spells
            g[#g + 1] = sp
        end
    end

    local function byName(a, b) return strlower(a.name) < strlower(b.name) end
    local entries = {}
    for _, g in ipairs(groups) do
        table.sort(g.spells, byName)
        entries[#entries + 1] = { header = NS.WithRu(g.header, NS.SPEC_RU) .. ":" }   -- "Arms:" and under it the spells of the group
        for _, sp in ipairs(g.spells) do entries[#entries + 1] = { spell = sp } end
    end
    local spells = list   -- (for the counter below)

    for i, e in ipairs(entries) do
        local row = NS.GetSpellRow(f, i)
        if e.header then
            row.spell = nil
            row.icon:Hide()
            row.hl:Hide()
            row.text:ClearAllPoints()
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetText("|cffffd100" .. e.header .. "|r")
        else
            local sp = e.spell
            row.spell = sp
            row.icon:SetTexture(NS.SpellIcon(sp))
            row.icon:Show()
            row.hl:Show()
            row.text:ClearAllPoints()
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
            -- the link keeps the server's (English) name; the client's own (Russian) name
            -- follows after a space, per explicit user direction
            local clientName = GetSpellInfo(sp.id)
            local extra = ""
            if clientName and strlower(clientName) ~= strlower(sp.name) then extra = " " .. clientName end
            row.text:SetText((sp.link or sp.name) .. extra)
        end
        row:Show()
    end
    for i = #entries + 1, #f.rows do
        f.rows[i].spell = nil
        f.rows[i]:Hide()
    end
    f.content:SetHeight(math.max(10, #entries * NS.SPELL_ROW_H))

end

NS.ToggleBotSpellbook = function(botName)
    local f = NS.GetSpellFrame(botName)
    if f:IsShown() then
        f:Hide()
        return
    end
    local key = strlower(botName)
    if not NS.botSpellState[key] then NS.LoadSpellCache(key) end   -- instantly from the saved list
    NS.PaintSpellbook(key)
    f:Show()
    NS.FetchBotSpells(botName)   -- and refresh it in the background
end

-- ============================================================
-- Minimap icon + form: the primary UI. A small draggable button on the
-- minimap opens a form with ONE textarea (space-separated names/class
-- tokens/comments — see file header) and 3 mode radio buttons underneath.
-- There is no Save button — closing the form (X, or the minimap icon again)
-- IS saving: OnHide parses the textarea, stores the result, and calls
-- NS.ApplyMode. No "discovery" beyond believing whatever's typed here.
-- ============================================================

local form = CreateFrame("Frame", "AltBotForm", UIParent)
form:SetSize(260, 300)
form:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
form:SetMovable(true)
form:EnableMouse(true)
form:RegisterForDrag("LeftButton")
form:SetScript("OnDragStart", form.StartMoving)
form:SetScript("OnDragStop", form.StopMovingOrSizing)
form:SetFrameStrata("DIALOG")
form:Hide()

local formBg = form:CreateTexture(nil, "BACKGROUND")
formBg:SetAllPoints(form)
formBg:SetTexture(0, 0, 0, 0.85)

local formBorder = CreateFrame("Frame", nil, form)
formBorder:SetAllPoints(form)
formBorder:SetBackdrop({
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
})
formBorder:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

local title = form:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", form, "TOP", 0, -12)
title:SetText("AltBot")

local closeBtn = CreateFrame("Button", nil, form, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", form, "TOPRIGHT", -4, -4)
closeBtn:SetScript("OnClick", function() form:Hide() end)

-- Backdrop frame behind the scroll area — UIPanelScrollFrameTemplate has no
-- texture of its own, and neither does a bare EditBox, so without this the
-- textarea is an invisible click target with no visual cue it exists.
local textareaBg = CreateFrame("Frame", nil, form)
textareaBg:SetPoint("TOP", title, "BOTTOM", 0, -14)
textareaBg:SetSize(220, 210)
textareaBg:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
})
textareaBg:SetBackdropColor(0, 0, 0, 0.8)
textareaBg:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

local scrollFrame = CreateFrame("ScrollFrame", "AltBotFormScroll", textareaBg, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", textareaBg, "TOPLEFT", 8, -8)
scrollFrame:SetPoint("BOTTOMRIGHT", textareaBg, "BOTTOMRIGHT", -28, 8)

local botTextarea = CreateFrame("EditBox", nil, scrollFrame)
botTextarea:SetMultiLine(true)
botTextarea:SetFontObject(ChatFontNormal)
botTextarea:SetWidth(184)
-- Taller than the visible scroll area on purpose — UIPanelScrollFrameTemplate
-- clips to scrollFrame's own height and scrolls the rest; an EditBox with no
-- explicit height can end up 0-height before any text is typed, breaking
-- click-to-focus in the empty control.
botTextarea:SetHeight(400)
botTextarea:SetAutoFocus(false)
botTextarea:EnableMouse(true)
botTextarea:SetScript("OnEscapePressed", botTextarea.ClearFocus)
scrollFrame:SetScrollChild(botTextarea)

-- Clicking anywhere in the visible scroll area (not just directly on the
-- EditBox's own mouse-hit region, which can be narrower than the backdrop)
-- focuses the textarea, same as clicking a normal input field.
scrollFrame:EnableMouse(true)
scrollFrame:SetScript("OnMouseDown", function() botTextarea:SetFocus() end)
textareaBg:EnableMouse(true)
textareaBg:SetScript("OnMouseDown", function() botTextarea:SetFocus() end)

-- ── Save button — the roster editor's ONLY other control besides the
-- textarea. Mode switching, combat reaction, and the roster-lifecycle
-- actions (Reset/Disband) all moved to the action bar (below, right-click
-- the minimap icon) — this form is just "type names, Save".
local saveBtn = CreateFrame("Button", nil, form, "UIPanelButtonTemplate")
saveBtn:SetSize(220, 22)
saveBtn:SetPoint("TOPLEFT", textareaBg, "BOTTOMLEFT", 0, -10)
saveBtn:SetText("Save")
saveBtn:SetScript("OnClick", function()
    NS.SaveForm()
    NS.RefreshForm()
    -- Force ApplyMode to re-apply the current mode's strategy too, not just
    -- skip it because AltBot_SavedVars.mode itself didn't change (see
    -- ApplyMode's `mode ~= NS.lastAppliedMode` guard) - Save should fully
    -- resync every tracked bot to the new roster, same as what a fresh
    -- login/reload already does (NS.lastAppliedMode starts nil there too).
    NS.lastAppliedMode = nil
    NS.ApplyMode()
    if NS.RefreshActionBar then NS.RefreshActionBar() end
end)

--- Parses the textarea via ParseRosterText and commits the result into
--- AltBot_SavedVars. The saved/redisplayed text (rosterText) is the exact
--- typed text, untouched — whitespace-collapsing/comment-stripping only
--- happens inside ParseRosterText, for botNames/classCounts, not for what
--- reopening the form shows.
--- classCounts is persisted as a standing quota (see ParseRosterText's doc
--- comment) — enforcement happens in GroupRoster/ApplyMode, not here.
--- NS field (not local) because the Save button above and the action bar's
--- mode buttons (further below) both need to call it.
NS.SaveForm = function()
    AltBot_SavedVars = AltBot_SavedVars or {}
    -- Persisted/redisplayed exactly as typed - no whitespace collapsing,
    -- no comment stripping (per explicit user direction: the roster text
    -- should be saved exactly as it originally was). ParseRosterText still
    -- normalizes/strips comments internally when extracting botNames -
    -- that's a separate concern from what the textarea shows. rosterText is
    -- the ONLY roster-related field actually persisted to AltBot_SavedVars
    -- (account-wide, not per-character NS.CharVars — the roster is one
    -- shared thing for the whole account, per explicit user direction:
    -- "ростер должен быть один на аккаунт, а не у каждого чара свой").
    --
    -- botNames/classCounts are NOT persisted here (or anywhere) any more —
    -- only kept in-memory as NS.currentBotNames/NS.currentClassCounts,
    -- recomputed from rosterText by BuildRosterFromNames every time they're
    -- needed (see its own doc comment for the staleness bug this replaced:
    -- persisting botNames meant whichever character was master at the LAST
    -- Save stayed excluded from it forever, even after a different
    -- character became master and that name should have reappeared as a
    -- tracked bot). Per explicit user direction: "конечно же имена ботов
    -- нужно вычислять каждый раз заново и нигде не хранить, храним мы
    -- только текст ростера и моду... больше нам ничего хранить не нужно
    -- между сессиями". Set here too (not just left to the next
    -- BuildRosterFromNames call) so callers reading NS.currentBotNames
    -- immediately after Save — before anything else re-triggers a rebuild —
    -- see this save's result right away.
    local typed = botTextarea:GetText() or ""
    AltBot_SavedVars.rosterText = typed
    local parsed = ParseRosterText(typed)
    NS.currentBotNames    = parsed.botNames
    NS.currentClassCounts = parsed.classCounts
    NS.currentSlots       = parsed.slots
end

--- Reloads the textarea from the account-wide saved text (see SaveForm's own
--- doc comment for why this isn't per-character). (Mode/reaction
--- highlighting used to live here too — see NS.RefreshActionBar now.)
NS.RefreshForm = function()
    botTextarea:SetText((AltBot_SavedVars and AltBot_SavedVars.rosterText) or "")
end

-- No OnHide handler — closing the form (X button, the Roster action-bar
-- button toggling it shut, Escape) no longer saves anything by itself.
-- Save is the ONLY thing that commits the textarea; closing without it
-- just discards whatever's typed (OnShow below reloads the last saved
-- text next time the form opens, so nothing "leaks" between opens).
form:SetScript("OnShow", NS.RefreshForm)

-- ============================================================
-- Action bar: a single-row, pet-style bar of icon buttons, shown/hidden via
-- the minimap icon's RIGHT-click (left-click still opens the roster form
-- above). Modeled directly on WoW's own Pet Action Bar
-- (Interface/FrameXML/PetActionBarFrame.lua, confirmed against the actual
-- 3.3.5 client source), left to right: Attack (one-shot), Follow/Stay
-- (mutually exclusive, Follow active by default), its combat reaction
-- (Aggressive/Defensive/Passive, also mutually exclusive — these 4
-- textures ARE Blizzard's own PET_*_TEXTURE constants from that file, not
-- guesses), AltBot's roster-lifecycle modes (Summon/Free Roam — labels
-- describe the visible effect, not the internal mode name; MODE_QUEST/
-- MODE_FARM underneath are unchanged. Учёба has no button for now, see
-- MODE_ROW's comment — same job MODE_BUTTONS used to do), then Disband
-- ("Abandon Pet" — see DisbandRoster) + the roster editor's own toggle.
-- No Revive/Eat-Drink buttons — removed on request, both already happen on
-- their own (bots eat/drink automatically whenever idle; dead bots are
-- already auto-recovered by NS.CheckReviveBots' "summon" ticker), so
-- manual buttons for them were redundant.
--
-- The first 6 buttons (Attack/Follow/Stay/Aggressive/Defensive/Passive)
-- only make sense while you're actively directing the group, so they're
-- shown ONLY in Summon (Квест) mode — hidden in Free Roam (Фарм), and
-- hidden if no mode is set yet (see ReflowActionBar).
--
-- Summon/Free Roam use the real Call Pet/Dismiss Pet spell icons
-- (confirmed against Wowhead/the pet-bar source, not guessed); Disband/
-- Roster are reasonable picks — swap the texture path if one looks wrong
-- in-game, it's a one-line edit.
-- ============================================================
local ACTION_BTN    = 28
local ACTION_GAP    = 4
local ACTION_PAD    = 6
local ACTION_EAR_W  = 0    -- no separate drag ear any more: the last (empty) icon is the drag handle
local ACTION_TOTAL_BTNS = 12   -- 1 + 2 + 3 + 2 + 1 + 1 + settings gear + drag handle (every group below, in order)

--- Small square icon button shared by every action-bar slot. `onClick`
--- receives no arguments; a mode/reaction button flips its own highlight
--- via the returned button's SetActive, driven by NS.RefreshActionBar.
local function CreateActionIconButton(parent, texture, title, desc, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(ACTION_BTN, ACTION_BTN)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn)
    bg:SetTexture(0, 0, 0, 1)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    icon:SetTexture(texture)

    local border = CreateFrame("Frame", nil, btn)
    border:SetAllPoints(btn)
    border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 8 })
    border:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(btn)
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    local pushed = btn:CreateTexture(nil, "OVERLAY")
    pushed:SetAllPoints(btn)
    pushed:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    pushed:SetBlendMode("ADD")
    pushed:Hide()

    btn.SetActive = function(self, active)
        if active then pushed:Show() else pushed:Hide() end
    end

    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(title, 1, 1, 1)
        if desc then GameTooltip:AddLine(desc, 1, 0.82, 0, true) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return btn
end

local actionBar = CreateFrame("Frame", "AltBotActionBar", UIParent)
actionBar:SetSize(
    ACTION_PAD * 2 + ACTION_BTN * ACTION_TOTAL_BTNS + ACTION_GAP * (ACTION_TOTAL_BTNS - 1) + ACTION_EAR_W,
    ACTION_PAD * 2 + ACTION_BTN)
actionBar:SetPoint("CENTER", UIParent, "CENTER", -200, 0)
actionBar:SetFrameStrata("MEDIUM")
actionBar:SetMovable(true)
actionBar:Hide()

local actionBarBg = actionBar:CreateTexture(nil, "BACKGROUND")
actionBarBg:SetAllPoints(actionBar)
actionBarBg:SetTexture(0, 0, 0, 0.6)

local actionBarBorder = CreateFrame("Frame", nil, actionBar)
actionBarBorder:SetAllPoints(actionBar)
actionBarBorder:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
actionBarBorder:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

--- Every action-bar button, in left-to-right build order. `combatOnly`
--- buttons (Attack/Follow/Stay/Aggressive/Defensive/Passive) only show in
--- Summon (Квест) mode — see ReflowActionBar, which is what actually
--- positions everything (registering here just records build order + the
--- combatOnly flag; it doesn't anchor anything by itself).
local actionBarSlots = {}
local function RegisterActionSlot(btn, combatOnly)
    actionBarSlots[#actionBarSlots + 1] = { btn = btn, combatOnly = combatOnly }
    return btn
end

-- ── Slide animation for the combat-only slots appearing/disappearing ──
-- By build order the first COMBAT_SLOT_COUNT slots are always the
-- combat-only ones (Attack/Follow/Stay/Aggressive/Defensive/Passive) and
-- everything after is always visible (Summon/Free Roam/Disband/Roster) -
-- so showing/hiding the first 6 is just a uniform shift of the rest plus a
-- width change, not a general reflow. `combatShownFrac` (0 = hidden,
-- 1 = shown) is the ONE piece of state that persists across toggles/
-- interrupted animations; everything else here is a pure function of it,
-- computed from fixed endpoints (never read back from the live frames, so
-- there's no UI-scale ambiguity between logical SetPoint offsets and
-- GetLeft()'s screen-space coordinates).
local COMBAT_SLOT_COUNT = 6
local ACTION_SLIDE_TIME = 0.15

local function ActionBarColX(col)
    return ACTION_PAD + col * (ACTION_BTN + ACTION_GAP)
end

local otherCount, narrowWidth, wideWidth
local otherCollapsedX, otherExpandedX = {}, {}

--- Call once, after every button has been created/registered (see below) -
--- fixes the combat/other split point and precomputes every endpoint the
--- animation interpolates between.
local function InitActionBarLayout()
    otherCount = #actionBarSlots - COMBAT_SLOT_COUNT
    narrowWidth = ACTION_PAD * 2 + ACTION_BTN * otherCount
        + ACTION_GAP * math.max(otherCount - 1, 0) + ACTION_EAR_W
    wideWidth = ACTION_PAD * 2 + ACTION_BTN * (COMBAT_SLOT_COUNT + otherCount)
        + ACTION_GAP * (COMBAT_SLOT_COUNT + otherCount - 1) + ACTION_EAR_W
    for idx = 1, otherCount do
        otherCollapsedX[idx] = ActionBarColX(idx - 1)
        otherExpandedX[idx]  = ActionBarColX(COMBAT_SLOT_COUNT + idx - 1)
    end
    -- Combat slots never move, only fade - position them once at their
    -- fixed columns and start hidden/transparent.
    for i = 1, COMBAT_SLOT_COUNT do
        local btn = actionBarSlots[i].btn
        btn:SetPoint("TOPLEFT", actionBar, "TOPLEFT", ActionBarColX(i - 1), -ACTION_PAD)
        btn:Hide()
        btn:SetAlpha(0)
    end
end

local combatShownFrac = 0

--- Applies one animation frame (or the final/resting state) for a given
--- fraction shown, 0..1.
local function ApplyActionBarFrac(frac)
    combatShownFrac = frac
    actionBar:SetWidth(narrowWidth + (wideWidth - narrowWidth) * frac)
    for idx = 1, otherCount do
        local btn = actionBarSlots[COMBAT_SLOT_COUNT + idx].btn
        local x = otherCollapsedX[idx] + (otherExpandedX[idx] - otherCollapsedX[idx]) * frac
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", actionBar, "TOPLEFT", x, -ACTION_PAD)
    end
    if frac > 0 then
        for i = 1, COMBAT_SLOT_COUNT do
            local btn = actionBarSlots[i].btn
            btn:Show()
            btn:SetAlpha(frac)
        end
    end
    if frac <= 0 then
        for i = 1, COMBAT_SLOT_COUNT do
            actionBarSlots[i].btn:Hide()
        end
    end
end

local actionBarSlideFrame = CreateFrame("Frame")
actionBarSlideFrame:Hide()

--- Slides the combat-only slots in/out (see above) to match whether we're
--- in Summon mode, animating from wherever the bar currently is - even
--- mid-animation, since combatShownFrac is read live, not cached per-call.
local function ReflowActionBar()
    local targetFrac = (NS.EffectiveMode() == NS.MODE_QUEST) and 1 or 0
    local startFrac = combatShownFrac
    if startFrac == targetFrac then
        ApplyActionBarFrac(targetFrac)
        return
    end
    local elapsed = 0
    actionBarSlideFrame:Show()
    actionBarSlideFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        local t = math.min(elapsed / ACTION_SLIDE_TIME, 1)
        ApplyActionBarFrac(startFrac + (targetFrac - startFrac) * t)
        if t >= 1 then
            self:Hide()
            self:SetScript("OnUpdate", nil)
        end
    end)
end

-- Attack — one-shot, broadcast to the whole group (SendGroupCommand), no
-- active state (there's nothing to stay "attacking").
local attackBtn = RegisterActionSlot(CreateActionIconButton(actionBar, "Interface\\Icons\\Ability_GhoulFrenzy",
    "Attack", "Attack your current target.",
    function() SendGroupCommand("do attack my target") end), true)

-- Follow / Stay — mutually exclusive movement toggle (same pattern as the
-- reaction row below), Follow active by default since that's the group's
-- actual default behavior.
local MOVEMENT_ROW = {
    { movement = NS.MOVEMENT_FOLLOW, texture = "Interface\\Icons\\Ability_Tracking",
      title = "Follow", desc = "Follow you.", cmd = "follow" },
    { movement = NS.MOVEMENT_STAY, texture = "Interface\\Icons\\Spell_Nature_TimeStop",
      title = "Stay", desc = "Stay in place.", cmd = "stay" },
}
local movementBtns = {}
for i, def in ipairs(MOVEMENT_ROW) do
    local btn = CreateActionIconButton(actionBar, def.texture, def.title, def.desc,
        function()
            AltBot_SavedVars = AltBot_SavedVars or {}
            AltBot_SavedVars.movement = def.movement
            SendGroupCommand(def.cmd)
            NS.RefreshActionBar()
        end)
    RegisterActionSlot(btn, true)
    movementBtns[i] = btn
end

-- Row 2 — combat reaction, mutually exclusive. Textures are Blizzard's own
-- PET_AGGRESSIVE_TEXTURE / PET_DEFENSIVE_TEXTURE / PET_PASSIVE_TEXTURE.
local REACTION_ROW = {
    { reaction = NS.REACTION_AGGRESSIVE, texture = "Interface\\Icons\\Ability_Racial_BloodRage",
      title = "Aggressive", desc = "Attack any hostile that comes near." },
    { reaction = NS.REACTION_DEFENSIVE, texture = "Interface\\Icons\\Ability_Defend",
      title = "Defensive", desc = "Fight back only when attacked (the neutral default)." },
    { reaction = NS.REACTION_PASSIVE, texture = "Interface\\Icons\\Ability_Seal",
      title = "Passive", desc = "Never engage in combat." },
}
local reactionBtns = {}
for i, def in ipairs(REACTION_ROW) do
    local btn = CreateActionIconButton(actionBar, def.texture, def.title, def.desc,
        function() ApplyReaction(def.reaction) end)
    RegisterActionSlot(btn, true)
    reactionBtns[i] = btn
end

-- Row 3 — the 2 real roster-lifecycle modes (Solo, the 3rd, has no button
-- of its own here - see Disband below). Still sets AltBot_SavedVars.mode =
-- MODE_QUEST/MODE_FARM under the hood and calls ApplyMode() exactly as
-- before — only the bar's own labels changed, to describe what each click
-- visibly does rather than the internal mode name: "Summon" (Квест) just
-- brings the roster to you, whatever you're actually doing; "Free Roam"
-- (Фарм) is the movement behavior that mode leaves bots in between fights.
-- No more Учёба/Study button or mode at all — see the TRAINER_UPDATE
-- watcher near TrainBots for what replaced it (fires in either mode here).
local MODE_ROW = {
    { mode = NS.MODE_QUEST, texture = "Interface\\Icons\\Ability_Hunter_BeastCall",
      title = "Quest Mode", desc = "Summons the whole roster to you." },
    { mode = NS.MODE_FARM, texture = "Interface\\Icons\\Spell_Nature_SpiritWolf",
      title = "Farm Mode", desc = "Bots roam and grind freely." },
}
local modeBtns = {}
for i, def in ipairs(MODE_ROW) do
    local btn = CreateActionIconButton(actionBar, def.texture, def.title, def.desc,
        function()
            -- Mirrors the old MODE_BUTTONS OnClick: save + apply
            -- immediately (see the fresh-install flow in the file header).
            -- Account-wide AltBot_SavedVars.mode, NOT NS.CharVars() — mode
            -- is shared across the whole account (per explicit user
            -- direction: "режим моды должен быть один для аккаунта"), same
            -- field DisbandRoster sets to MODE_SOLO.
            AltBot_SavedVars.mode = def.mode
            NS.SaveForm()
            NS.RefreshForm()
            -- SendGroupCommand("summon") must wait for ApplyMode's own
            -- GroupRoster to actually finish (it's async — WaitForGroupToSettle
            -- runs over several NS.After delays) rather than firing right
            -- after ApplyMode() returns. Right after a Disband the group is
            -- completely empty, so a synchronous SendGroupCommand here always
            -- hit the "not in a party or raid" branch before the party had a
            -- chance to form (confirmed by the user in-game).
            NS.ApplyMode(function()
                if def.mode == NS.MODE_QUEST then
                    SendGroupCommand("summon")
                    NS.After(3.0, function() NS.WarmAllArmoryModels() end)   -- the bots have arrived by then
                end
            end)
            NS.RefreshActionBar()
        end)
    RegisterActionSlot(btn, false)
    modeBtns[i] = btn
end

-- Disband, and the roster editor's own toggle (the minimap icon no longer
-- opens it directly — see the minimap icon section below).
local disbandBtn = RegisterActionSlot(CreateActionIconButton(actionBar, "Interface\\Icons\\Ability_Kick",
    "Solo Mode", "Despawn the whole roster and leave you alone.", DisbandRoster), false)

-- Tame Beast — "acquiring" the roster is the AltBot equivalent of taming a
-- pet in the first place.
local rosterBtn = RegisterActionSlot(CreateActionIconButton(actionBar, "Interface\\Icons\\Ability_Hunter_BeastTaming",
    "Roster", "Open the roster editor.",
    function()
        if form:IsShown() then form:Hide() else form:Show() end
    end), false)

-- Settings gear: opens/closes the settings form (the minimap icon has no right-click any
-- more), per explicit user direction.
RegisterActionSlot(CreateActionIconButton(actionBar, "Interface\\Icons\\INV_Misc_Gear_01",
    "Settings", "Open the settings window.",
    function() NS.ToggleSettings() end), false)

-- Empty icon = the bar's drag handle ("ушко"): grabbing IT moves the bar; the other icons
-- are never drag handles, so clicking one never risks an accidental move. Replaces the
-- old arrow on the bar's right edge.
local dragBtn = RegisterActionSlot(CreateActionIconButton(actionBar, "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up",
    "Move", "Drag to move the bar.", nil), false)
-- The grabber art only draws its ridges in the bottom-right corner; the same texture turned
-- 180 degrees gives the top-left twin (per explicit user direction).
local dragTwin = dragBtn:CreateTexture(nil, "ARTWORK")
dragTwin:SetPoint("TOPLEFT", dragBtn, "TOPLEFT", 2, -2)
dragTwin:SetPoint("BOTTOMRIGHT", dragBtn, "BOTTOMRIGHT", -2, 2)
dragTwin:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
dragTwin:SetTexCoord(1, 0, 1, 0)
dragBtn:RegisterForDrag("LeftButton")
dragBtn:SetScript("OnDragStart", function() actionBar:StartMoving() end)
dragBtn:SetScript("OnDragStop", function()
    actionBar:StopMovingOrSizing()
    local point, _, relPoint, x, y = actionBar:GetPoint()
    AltBot_SavedVars = AltBot_SavedVars or {}
    AltBot_SavedVars.actionBarPoint = { point, relPoint, x, y }
end)

InitActionBarLayout()

-- Keyboard shortcuts (Bindings.xml -> the standard "Key Bindings" window, section "AltBot"), per explicit user
-- direction. Each action does exactly what a click on the matching bar button does; the combat row (attack,
-- follow/stay, reactions) only exists in Quest mode, so the keys do nothing elsewhere.
NS.ClickButton = function(btn)
    local onClick = btn:GetScript("OnClick")
    if onClick then onClick(btn, "LeftButton") end
end
NS.QuestOnly = function(fn)
    return function()
        if NS.EffectiveMode() == NS.MODE_QUEST then fn() end
    end
end
NS.hotkeyActions = {
    attack     = NS.QuestOnly(function() NS.ClickButton(attackBtn) end),
    follow     = NS.QuestOnly(function() NS.ClickButton(movementBtns[1]) end),
    stay       = NS.QuestOnly(function() NS.ClickButton(movementBtns[2]) end),
    aggressive = NS.QuestOnly(function() NS.ClickButton(reactionBtns[1]) end),
    defensive  = NS.QuestOnly(function() NS.ClickButton(reactionBtns[2]) end),
    passive    = NS.QuestOnly(function() NS.ClickButton(reactionBtns[3]) end),
    quest      = function() NS.ClickButton(modeBtns[1]) end,
    farm       = function() NS.ClickButton(modeBtns[2]) end,
    solo       = function() NS.ClickButton(disbandBtn) end,
    roster     = function() NS.ClickButton(rosterBtn) end,
    settings   = function() NS.ToggleSettings() end,
    boardbar   = function()
        local showBoth = not (NS.BoardAnyShown() or actionBar:IsShown())
        NS.SetPanelShown(showBoth)
        NS.SetActionBarShown(showBoth)
    end,
    board      = function() NS.TogglePanel() end,
}

--- Called by the bodies of the bindings in Bindings.xml.
function AltBot_Hotkey(name)
    local action = NS.hotkeyActions[name]
    if action then action() end
end

-- The names shown in the Key Bindings window.
BINDING_HEADER_ALTBOT = "AltBot"
BINDING_NAME_ALTBOT_ATTACK = "Attack (Quest mode)"
BINDING_NAME_ALTBOT_FOLLOW = "Follow (Quest mode)"
BINDING_NAME_ALTBOT_STAY = "Stay (Quest mode)"
BINDING_NAME_ALTBOT_AGGRESSIVE = "Aggressive (Quest mode)"
BINDING_NAME_ALTBOT_DEFENSIVE = "Defensive (Quest mode)"
BINDING_NAME_ALTBOT_PASSIVE = "Passive (Quest mode)"
BINDING_NAME_ALTBOT_QUEST = "Quest Mode"
BINDING_NAME_ALTBOT_FARM = "Farm Mode"
BINDING_NAME_ALTBOT_SOLO = "Solo Mode"
BINDING_NAME_ALTBOT_ROSTER = "Roster"
BINDING_NAME_ALTBOT_SETTINGS = "Settings"
BINDING_NAME_ALTBOT_BOARDBAR = "Show / hide the board and the action bar"
BINDING_NAME_ALTBOT_BOARD = "Show / hide the board"

--- Highlights the active reaction + mode buttons, then reflows visibility
--- (see ReflowActionBar - the first 6 buttons only show in Summon mode).
--- Called on reaction/movement/mode changes and whenever the bar is
--- (re)shown.
NS.RefreshActionBar = function()
    local movement = NS.EffectiveMovement()
    for i, def in ipairs(MOVEMENT_ROW) do
        movementBtns[i]:SetActive(def.movement == movement)
    end
    local reaction = NS.EffectiveReaction()
    for i, def in ipairs(REACTION_ROW) do
        reactionBtns[i]:SetActive(def.reaction == reaction)
    end
    local mode = NS.EffectiveMode()
    for i, def in ipairs(MODE_ROW) do
        modeBtns[i]:SetActive(def.mode == mode)
    end
    disbandBtn:SetActive(mode == NS.MODE_SOLO)
    ReflowActionBar()
end

--- Shows/hides the action bar and persists the choice (mirrors the
--- minimap-icon-position save pattern below).
NS.SetActionBarShown = function(shown)
    AltBot_SavedVars = AltBot_SavedVars or {}
    AltBot_SavedVars.actionBarShown = shown and true or false
    if shown then
        NS.RefreshActionBar()
        actionBar:Show()
    else
        actionBar:Hide()
    end
end
NS.ToggleActionBar = function()
    NS.SetActionBarShown(not (AltBot_SavedVars and AltBot_SavedVars.actionBarShown))
end

-- ============================================================
-- Settings window — a single frame, independent of the bags/armory/strategy/
-- quest-log per-bot windows above (it's not per-bot, just one account-wide
-- settings panel), same backdrop/toplevel/raise-on-click shell. Currently
-- holds exactly one setting: "Sell Vendor" — off by default, sends "s *"
-- (sell everything the vendor buys) for bag-unload like before; on, sends
-- "s vendor" instead. Per explicit user direction ("пока в нем будет одна
-- настройка чекбокс с лабелью sell vendor по умолчанию выключена").
-- ============================================================
NS.SellCommand = function()
    if AltBot_SavedVars and AltBot_SavedVars.sellVendorOnly then
        return "s vendor"
    end
    return "s *"
end

local settingsFrame

-- Two sliders of the settings window (per explicit user direction): the polling interval of every bot
-- (default 30 s, 10..100) and the scale of the board frames (default 100 %, 50..150).
NS.POLL_INTERVAL_DEFAULT = 30
NS.ApplyPollInterval = function(seconds)
    NS.POLL_INTERVAL = seconds
    if #NS.rosterOrder > 0 then NS.STAGGER_DELAY = seconds / #NS.rosterOrder end
end
NS.ApplyBoardScale = function()
    local scale = ((AltBot_SavedVars and AltBot_SavedVars.boardScale) or 100) / 100
    for _, f in pairs(NS.boardFrames) do f:SetScale(scale) end
end

-- Memory of the addon itself: measured at the start and then several times an hour (every 5 minutes), one bar
-- per hour showing the average of its measurements (per explicit user direction), drawn as a bar chart at the top of the settings window - every sample one bar, the
-- bars sharing the window's width (a lone start bar fills it all, two bars half each, ten bars a tenth).
-- Values are in KB; the chart lives in memory (a /reload starts the Lua state, and the chart, afresh).
NS.MEM_SAMPLE_SECONDS = 300      -- a measurement every 5 minutes (12 an hour)
NS.MEM_BUCKET_SECONDS = 3600     -- ...and one bar of the chart per hour: the AVERAGE of that hour's measurements
NS.memSamples = {}   -- array of hourly buckets { t0 = time(), sum = KB, n = count, kb = average KB }

--- One measurement of the addon's memory; a single reading is not telling (garbage collection makes it
--- jump), so it goes into the current hour's average (per explicit user direction).
NS.SampleMemory = function()
    UpdateAddOnMemoryUsage()
    local kb = GetAddOnMemoryUsage("AltBot") or 0
    local bucket = NS.memSamples[#NS.memSamples]
    if not bucket or time() - bucket.t0 >= NS.MEM_BUCKET_SECONDS then
        bucket = { t0 = time(), sum = 0, n = 0, kb = 0 }
        NS.memSamples[#NS.memSamples + 1] = bucket
    end
    bucket.sum = bucket.sum + kb
    bucket.n = bucket.n + 1
    bucket.kb = bucket.sum / bucket.n
    NS.PaintMemChart()
end

NS.MemSampleLoop = function()
    NS.SampleMemory()
    NS.After(NS.MEM_SAMPLE_SECONDS, NS.MemSampleLoop)
end

--- Redraws the chart of the (existing) settings window from NS.memSamples.
NS.PaintMemChart = function()
    local f = NS.settingsFrame
    if not f or not f.chart then return end
    local samples = NS.memSamples
    local n = #samples
    local chart = f.chart
    local w, h = chart:GetWidth(), chart:GetHeight()
    local top = 1
    for _, smp in ipairs(samples) do top = math.max(top, smp.kb) end
    for i = 1, n do
        local bar = f.bars[i]
        if not bar then
            bar = chart:CreateTexture(nil, "ARTWORK")
            bar:SetTexture(0.3, 0.7, 0.3, 0.9)
            f.bars[i] = bar
        end
        local bw = w / n
        -- a visible gap between neighbouring bars (a lone start bar fills the whole width)
        local gap = (n > 1) and math.min(4, math.max(1, bw * 0.15)) or 0
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", (i - 1) * bw, 0)
        bar:SetSize(math.max(1, bw - gap), math.max(1, samples[i].kb / top * (h - 14)))
        bar:Show()
        -- up to 12 samples: the value centred above each bar, whole megabytes ("1MB")
        local text = f.barTexts[i]
        if n <= 12 then
            if not text then
                text = chart:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                text:SetTextColor(1, 1, 1)
                f.barTexts[i] = text
            end
            text:ClearAllPoints()
            text:SetPoint("BOTTOM", bar, "TOP", 0, 1)
            text:SetText(string.format("%dMB", math.floor(samples[i].kb / 1024 + 0.5)))
            text:Show()
        elseif text then
            text:Hide()
        end
    end
    for i = n + 1, #f.bars do
        f.bars[i]:Hide()
        if f.barTexts[i] then f.barTexts[i]:Hide() end
    end
    -- more than 12 hours: no per-bar values, the AVERAGE in the middle of the chart instead
    if n > 12 then
        local sum = 0
        for _, smp in ipairs(samples) do sum = sum + smp.kb end
        f.avgText:SetText(string.format("~%dMB", math.floor(sum / n / 1024 + 0.5)))
        f.avgText:Show()
    else
        f.avgText:Hide()
    end
end

local function GetOrCreateSettingsFrame()
    if settingsFrame then return settingsFrame end

    local COLS, COL_W, ROW_H = 4, 112, 24
    local f = CreateFrame("Frame", "AltBotSettings", UIParent)
    NS.settingsFrame = f
    f:SetWidth(COLS * COL_W + 32)
    f:SetHeight(90)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnMouseDown", function(self) self:Raise() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0, 0, 0, 1)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("AltBot Settings  v" .. (GetAddOnMetadata("AltBot", "Version") or "?"))

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- The memory chart on top, the checkboxes in 4 columns under it.
    local CHART_H = 90
    f.chart = CreateFrame("Frame", nil, f)
    f.chart:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -40)
    f.chart:SetSize(COLS * COL_W, CHART_H)
    local chartBg = f.chart:CreateTexture(nil, "BACKGROUND")
    chartBg:SetAllPoints(f.chart)
    chartBg:SetTexture(1, 1, 1, 0.06)
    f.bars = {}
    f.barTexts = {}
    f.avgText = f.chart:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.avgText:SetPoint("CENTER", f.chart, "CENTER", 0, 0)
    f.avgText:SetTextColor(1, 1, 1)
    f.avgText:Hide()
    f:SetScript("OnShow", function() NS.PaintMemChart() end)

    -- Two sliders under the chart: the polling interval and the board scale.
    local function MakeSlider(name, x, label, minV, maxV, current, format, onChange)
        local slider = CreateFrame("Slider", name, f, "OptionsSliderTemplate")
        slider:SetWidth(2 * COL_W - 24)
        slider:SetHeight(17)
        slider:SetPoint("TOPLEFT", f, "TOPLEFT", x + 6, -(40 + CHART_H + 26))
        slider:SetMinMaxValues(minV, maxV)
        slider:SetValueStep(1)
        _G[name .. "Low"]:SetText(tostring(minV))
        _G[name .. "High"]:SetText(tostring(maxV))
        local text = _G[name .. "Text"]
        text:SetText(string.format(format, current))
        slider.silent = true
        slider:SetValue(current)
        slider.silent = false
        slider:SetScript("OnValueChanged", function(self, value)
            if self.silent then return end
            value = math.floor(value + 0.5)
            text:SetText(string.format(format, value))
            onChange(value)
        end)
        return slider
    end
    MakeSlider("AltBotPollSlider", 16, "Poll interval", 10, 100,
        (AltBot_SavedVars and AltBot_SavedVars.pollInterval) or NS.POLL_INTERVAL_DEFAULT, "Poll interval: %d s",
        function(v)
            AltBot_SavedVars.pollInterval = v
            NS.ApplyPollInterval(v)
        end)
    MakeSlider("AltBotScaleSlider", 16 + 2 * COL_W, "Board scale", 50, 150,
        (AltBot_SavedVars and AltBot_SavedVars.boardScale) or 100, "Board scale: %d%%",
        function(v)
            AltBot_SavedVars.boardScale = v
            NS.ApplyBoardScale()
        end)

    -- The checkboxes, in blocks under the sliders (per explicit user direction): "sell vendor" + "delete cache"
    -- (with the two "fun" ones, "dance" and "emotes", beside them on the same row), the "hide" block, the "chat" block.
    local function item(label, get, set) return { label = label, get = get, set = set } end
    local sellItem = item("sell vendor",
        function() return AltBot_SavedVars and AltBot_SavedVars.sellVendorOnly or false end,
        function(v) AltBot_SavedVars.sellVendorOnly = v end)
    -- "delete cache": while ticked, the addon starts every time as if it were the very first run (see the
    -- ADDON_LOADED handler); the tick itself is a plain setting and is always remembered.
    local delItem = item("delete cache",
        function() return AltBot_SavedVars and AltBot_SavedVars.delCache or false end,
        function(v) AltBot_SavedVars.delCache = v end)
    -- "dance": every bot of the party dances; "emotes": every 5 minutes one random bot makes a random emote
    -- (see NS.fluffFrame); both work in Quest mode only. Off by default.
    local danceItem = item("dance",
        function() return AltBot_SavedVars and AltBot_SavedVars.dance or false end,
        function(v)
            AltBot_SavedVars.dance = v
            -- the master announces it in the chat (per explicit user direction)
            SendChatMessage(v and "Танцуют все!" or "Не до танцев сегодня, зима близко!", "SAY")
        end)
    local emotesItem = item("emotes",
        function() return AltBot_SavedVars and AltBot_SavedVars.emotes or false end,
        function(v) AltBot_SavedVars.emotes = v end)
    -- "hide gains / icons / names / bags / gold / xp / levels": which rows of the board columns are shown.
    local hideItems = {}
    for _, row in ipairs(NS.HIDE_ROWS) do
        hideItems[#hideItems + 1] = item(row.label,
            function() return NS.RowHidden(row.key) end,
            function(v)
                AltBot_SavedVars.hide = AltBot_SavedVars.hide or {}
                AltBot_SavedVars.hide[row.key] = v or nil
                NS.RefreshPanel()
            end)
    end
    -- "chat ...": one checkbox per chat area.
    local chatItems = {}
    for _, cat in ipairs(NS.CHAT_CATEGORIES) do
        chatItems[#chatItems + 1] = item(cat.label,
            function() return NS.ChatShown(cat.key) end,
            function(v)
                AltBot_SavedVars.chatShow = AltBot_SavedVars.chatShow or {}
                AltBot_SavedVars.chatShow[cat.key] = v
            end)
    end

    local BLOCK_GAP = 10
    local y = 40 + CHART_H + 8 + 48   -- (the sliders sit between the chart and the checkboxes)
    local function place(it, col, row)
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + col * COL_W, -(y + row * ROW_H))
        cb:SetChecked(it.get())
        cb:SetScript("OnClick", function(self)
            AltBot_SavedVars = AltBot_SavedVars or {}
            it.set(self:GetChecked() and true or false)
        end)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        label:SetText(it.label)
        label:SetTextColor(1, 1, 1)
    end
    -- block 1: sell vendor, dance, emotes and, last, delete cache - one row
    place(sellItem, 0, 0)
    place(danceItem, 1, 0)
    place(emotesItem, 2, 0)
    place(delItem, 3, 0)   -- "delete cache" is always the last of the row
    y = y + ROW_H + BLOCK_GAP
    -- block 2: hide
    for n, it in ipairs(hideItems) do place(it, (n - 1) % COLS, math.floor((n - 1) / COLS)) end
    y = y + math.ceil(#hideItems / COLS) * ROW_H + BLOCK_GAP
    -- block 3: chat
    for n, it in ipairs(chatItems) do place(it, (n - 1) % COLS, math.floor((n - 1) / COLS)) end
    y = y + math.ceil(#chatItems / COLS) * ROW_H
    f:SetHeight(y + 18)

    f:Hide()
    settingsFrame = f
    return f
end

NS.ToggleSettings = function()
    local f = GetOrCreateSettingsFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

-- "dance" / "emotes" from the settings window (per explicit user direction): with "dance" on the group is told
-- "emote dance" every NS.DANCE_REPEAT seconds (a dance is cancelled as soon as a bot moves, so it is renewed);
-- with "emotes" on, every NS.EMOTE_SECONDS one random bot gets a random emote. Quest mode only.
NS.DANCE_REPEAT = 10
NS.EMOTE_SECONDS = 300
-- every emote with an animation, from onlinegamecommands.com/world-warcraft-emotes (column "A" = X); kiss, train and
-- victory included
NS.EMOTES = {
    "agree", "amaze", "angry", "applaud", "applause", "attacktarget", "bashful", "beckon", "beg", "blush",
    "blow", "boggle", "bonk", "bored", "bow", "bravo", "brb", "bye", "cackle", "cheer", "chew", "chicken",
    "chuckle", "clap", "cold", "comfort", "commend", "confused", "cong", "congrats", "congratulate", "cry",
    "curious", "curtsey", "dance", "disappointed", "disappointment", "drink", "excited", "eye", "farewell",
    "fear", "feast", "fidget", "flap", "flex", "flirt", "followme", "gaze", "giggle", "glad", "gloat",
    "golfclap", "goodbye", "grovel", "growl", "guffaw", "hail", "happy", "hello", "helpme", "hi", "incoming",
    "insult", "kiss", "kneel", "laugh", "lavish", "lay", "laydown", "lie", "liedown", "listen", "lol",
    "lost", "love", "mad", "massage", "mock", "moo", "mourn", "no", "nod", "nosepick", "oom", "openfire",
    "panic", "party", "pat", "peer", "peon", "pity", "plead", "point", "poke", "ponder", "pounce", "praise",
    "pray", "puzzled", "rasp", "rdy", "ready", "roar", "rofl", "rude", "salute", "shake", "shimmy",
    "shindig", "shy", "sigh", "silly", "sleep", "smile", "smirk", "snarl", "snicker", "sniff", "snub", "sob",
    "soothe", "spit", "stare", "strong", "strut", "surprise", "surrender", "talk", "talkex", "talkq",
    "taunt", "thank", "thanks", "threat", "threaten", "tickle", "train", "ty", "victory", "violin",
    "volunteer", "wait", "wave", "weep", "welcome", "whistle", "wicked", "wickedly", "wink", "yawn", "yes",
}
NS.fluffClock = { dance = 0, emote = 0 }
NS.fluffFrame = CreateFrame("Frame")
NS.fluffFrame:SetScript("OnUpdate", function(self, dt)
    self.acc = (self.acc or 0) + dt
    if self.acc < 1 then return end
    local elapsed = self.acc
    self.acc = 0
    local sv = AltBot_SavedVars
    if not sv or NS.EffectiveMode() ~= NS.MODE_QUEST or not NS.boardReady then return end   -- Quest mode only
    if sv.dance then
        NS.fluffClock.dance = NS.fluffClock.dance + elapsed
        if NS.fluffClock.dance >= NS.DANCE_REPEAT then
            NS.fluffClock.dance = 0
            if GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then SendGroupCommand("emote dance") end
        end
    else
        NS.fluffClock.dance = NS.DANCE_REPEAT   -- the first dance goes out at once when it is ticked
    end
    if sv.emotes then
        NS.fluffClock.emote = NS.fluffClock.emote + elapsed
        if NS.fluffClock.emote >= NS.EMOTE_SECONDS then
            NS.fluffClock.emote = 0
            local pool = {}
            for _, key in ipairs(NS.rosterOrder) do
                if NS.bots[key] and not NS.bots[key].wasDead then pool[#pool + 1] = NS.bots[key] end
            end
            if #pool > 0 then
                local bot = pool[math.random(#pool)]
                SendBotCommand(bot.name, "emote " .. NS.EMOTES[math.random(#NS.EMOTES)])
            end
        end
    else
        NS.fluffClock.emote = 0
    end
end)

NS.After(5, NS.MemSampleLoop)   -- the first measurement a few seconds after the start, then every NS.MEM_SAMPLE_SECONDS

-- Minimap icon — a small draggable button orbiting the minimap, standard
-- pattern for addon minimap buttons in 3.3.5 (no LibDBIcon dependency, kept
-- minimal on purpose).
local minimapIcon = CreateFrame("Button", "AltBotMinimapIcon", Minimap)
minimapIcon:SetSize(31, 31)
minimapIcon:SetFrameStrata("MEDIUM")
minimapIcon:SetFrameLevel(8)
minimapIcon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapIcon:RegisterForDrag("LeftButton")

local iconTexture = minimapIcon:CreateTexture(nil, "BACKGROUND")
iconTexture:SetSize(20, 20)
iconTexture:SetPoint("CENTER", minimapIcon, "CENTER", 0, 0)
iconTexture:SetTexture("Interface\\Icons\\Spell_Nature_Polymorph")

local iconBorder = minimapIcon:CreateTexture(nil, "OVERLAY")
iconBorder:SetSize(52, 52)
iconBorder:SetPoint("TOPLEFT", minimapIcon, "TOPLEFT", 0, 0)
iconBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

--- Places the icon at `angleDeg` degrees around the minimap's edge.
local function PositionMinimapIcon(angleDeg)
    local rad = math.rad(angleDeg)
    local radius = 80
    minimapIcon:ClearAllPoints()
    minimapIcon:SetPoint("CENTER", Minimap, "CENTER",
        -radius * math.cos(rad), radius * math.sin(rad))
end

local savedAngle = 215   -- default position; overwritten by ADDON_LOADED if saved
PositionMinimapIcon(savedAngle)

-- Drag-to-reposition, ported from CleanBot's Minimap.lua pattern (GetCursorPosition +
-- atan2, normalized to 0-360 so the angle never drifts out of a sane range across
-- the +/-180 wrap).
local draggingIcon = false
minimapIcon:SetScript("OnDragStart", function(self) draggingIcon = true end)
minimapIcon:SetScript("OnDragStop", function(self) draggingIcon = false end)
minimapIcon:SetScript("OnUpdate", function(self)
    if not draggingIcon then return end
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not (mx and px and scale and scale ~= 0) then return end
    px, py = px / scale, py / scale
    local angleDeg = math.deg(math.atan2(py - my, px - mx)) % 360
    savedAngle = angleDeg
    PositionMinimapIcon(angleDeg)
    AltBot_SavedVars = AltBot_SavedVars or {}
    AltBot_SavedVars.minimapAngle = angleDeg
end)

-- Click: toggles BOTH the stats board and the action bar together - per explicit user
-- direction ("клик по иконке открывает/закрывает табло и экшенбар"); no right-click
-- (settings are opened by the gear on the action bar). Right click: only the board. NOT two independent toggles:
-- NS.TogglePanel()/NS.ToggleActionBar() each flip their OWN saved flag, so if the two ever
-- drifted out of sync a click would show one and hide the other. Decide a single target
-- state from whether EITHER is visible, then force both to it.
minimapIcon:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        NS.TogglePanel()   -- right click: the stats board only
        return
    end
    local showBoth = not (NS.BoardAnyShown() or actionBar:IsShown())
    NS.SetPanelShown(showBoth)
    NS.SetActionBarShown(showBoth)
end)

minimapIcon:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("AltBot", 1, 1, 1)
    GameTooltip:AddLine("Left click: stats board + action bar.", 1, 1, 1)
    GameTooltip:AddLine("Right click: stats board only.", 1, 1, 1)
    GameTooltip:Show()
end)
minimapIcon:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ============================================================
-- Load/resume: restore saved fields and minimap position, then apply
-- whatever roster/mode is saved — there's no per-character farmer/trainer
-- gating any more; every login/reload just re-syncs to the saved state.
-- ============================================================
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName ~= ADDON_NAME then return end
        AltBot_SavedVars = AltBot_SavedVars or {}
        -- See this field's own doc comment (near bagsItemsAwaiting) for why
        -- this has to happen here, in ADDON_LOADED, and not at file top
        -- level.
        -- "del cache" (Settings, first item): start the addon as if it were the very
        -- first time - EVERYTHING persistent goes (caches, the other Settings
        -- checkboxes, roster text, mode, window positions, per-character state), and
        -- only the "del cache" tick itself is kept, so the next start does it again.
        if AltBot_SavedVars.delCache then
            for k in pairs(AltBot_SavedVars) do AltBot_SavedVars[k] = nil end
            AltBot_SavedVars.delCache = true
        end
        AltBot_SavedVars.bagsCache = AltBot_SavedVars.bagsCache or {}
        -- Armory equipment cache (icons + item links for the tooltips) lives in the
        -- saved variables, so it survives /reload and relog (per explicit user
        -- direction); every reader goes through NS.botEquipCache/NS.botEquipLinks.
        AltBot_SavedVars.equipCache = AltBot_SavedVars.equipCache or {}
        AltBot_SavedVars.equipLinks = AltBot_SavedVars.equipLinks or {}
        AltBot_SavedVars.equipCacheVersion = nil
        NS.botEquipCache = AltBot_SavedVars.equipCache
        NS.botEquipLinks = AltBot_SavedVars.equipLinks
        -- Last "who" data per bot (armory header), kept the same way.
        AltBot_SavedVars.botWho = AltBot_SavedVars.botWho or {}
        NS.botWho = AltBot_SavedVars.botWho
        NS.ApplyPollInterval(AltBot_SavedVars.pollInterval or NS.POLL_INTERVAL_DEFAULT)
        if AltBot_SavedVars.minimapAngle then
            PositionMinimapIcon(AltBot_SavedVars.minimapAngle)
        end
        -- Board frames restore their own saved positions when first created (NS.GetBoardFrame).
        local ap = AltBot_SavedVars.actionBarPoint
        if ap then
            actionBar:ClearAllPoints()
            actionBar:SetPoint(ap[1], UIParent, ap[2], ap[3], ap[4])
        end
        -- Solo needs no special restore here — it's just whatever's in
        -- AltBot_SavedVars.mode, same as Quest/Farm, so RefreshActionBar
        -- below already shows Disband highlighted/combat-row-hidden
        -- correctly on its own after a reload.
        NS.RefreshForm()
        NS.RefreshPanel()
        NS.RefreshActionBar()
        if AltBot_SavedVars.actionBarShown then actionBar:Show() end
        return
    end

    -- PLAYER_ENTERING_WORLD: fires on login, on /reload, and after a loading
    -- screen — the right point to (re-)apply. Only act once per session (a
    -- zone change also fires this event, and we don't want to re-group
    -- every time the player walks through a portal).
    if self.resumed then return end
    self.resumed = true

    -- A disband from before the disconnect/reload stays in effect: don't
    -- auto-resummon the roster just because the client restarted. No
    -- explicit check needed here — ApplyMode itself no-ops on MODE_SOLO
    -- (same persisted AltBot_SavedVars.mode as Quest/Farm), so scheduling
    -- it below is harmless; the user still has to click Summon/Free Roam
    -- (or Save) to actually bring the roster back.

    -- On a genuine disconnect/fresh login, playerbots don't persist as real
    -- characters — the group is empty and ApplyMode's GroupRoster must fully
    -- rebuild it. But PLAYER_ENTERING_WORLD also fires on a plain /reload,
    -- which only restarts the CLIENT UI — the group is untouched server-side
    -- the whole time. Per explicit user direction: "/reload не должен
    -- вызывать пересборку ростера... если ростер не менялся, вся группа в
    -- том составе который соответствует ростеру, то ничего пересобирать не
    -- нужно" — so RosterMatchesGroup is the ONE fork in the whole login flow:
    --   - Everything matches exactly (only a mild /reload gets here) -> just
    --     re-apply the mode directly, nobody kicked or told to leave.
    --   - ANYTHING is off (missing/extra/offline members, a master-switch
    --     collision, a genuine disconnect that dropped bots, etc.) -> full
    --     DisbandRoster() + rebuild, same as the user doing it by hand
    --     (per explicit user direction: "это общее правило, если хоть
    --     что-то не так при входе, то дисбанд и пересборка, только мягкий
    --     /reload проходят без этого, когда все одинаково"). No partial
    --     half-measures (a targeted whisper "leave", kicking just the
    --     mismatched names, etc.) for any of these cases — a clean full
    --     reset is simpler and was confirmed in-game to reliably recover
    --     from all of them, including ones a narrower fix wouldn't (e.g. a
    --     bot that's fully despawned, not just offline/mis-grouped, can't be
    --     reached by a per-name whisper at all).
    --
    -- Checking RosterMatchesGroup too early is actively dangerous, not just
    -- inaccurate: right after PLAYER_ENTERING_WORLD the client may not have
    -- received the server's actual group roster yet, so the check can see a
    -- still-empty group, wrongly conclude "doesn't match", and whisper
    -- "leave" to bots that were already fine — which is exactly what tore
    -- apart a working group on a plain /reload (confirmed by the user in-
    -- game). So wait for a real group-roster event (PARTY_MEMBERS_CHANGED/
    -- RAID_ROSTER_UPDATE) instead of a fixed delay — but still fall back to
    -- a timeout, since a genuinely empty group (fresh login, real disconnect
    -- that dropped the whole party) never fires either event to wait for.
    local rosterWaiter = CreateFrame("Frame")
    rosterWaiter:RegisterEvent("PARTY_MEMBERS_CHANGED")
    rosterWaiter:RegisterEvent("RAID_ROSTER_UPDATE")
    -- Guards against running twice — the event and the fallback timeout
    -- below are both live at once, and whichever fires first must stop the
    -- other from re-running this whole login flow a second time.
    local proceeded = false
    local function proceedWithLogin()
        if proceeded then return end
        proceeded = true
        rosterWaiter:UnregisterAllEvents()
        rosterWaiter:SetScript("OnEvent", nil)

        if NS.EffectiveMode() == NS.MODE_SOLO then
            NS.RefreshForm()
            NS.RefreshActionBar()
            return
        end

        BuildRosterFromNames()
        local names = NS.currentBotNames or {}

        if RosterMatchesGroup(names) then
            NS.ApplyMode()
            NS.RefreshForm()
            NS.RefreshActionBar()
            return
        end

        -- AltBot_SavedVars is account-wide (see the .toc's plain
        -- "SavedVariables", not "SavedVariablesPerCharacter"), so logging
        -- into a DIFFERENT master character inherits the exact same saved
        -- roster/mode immediately. If the PREVIOUS master's session ended
        -- without cleanly leaving its own group first, the tracked bots can
        -- still be attached to it (now offline, or fully despawned — mod-
        -- playerbots can despawn a master's own bots along with them when
        -- that master logs out, confirmed by the user in-game: switching
        -- from Para to Tara left every one of Para's bots answering
        -- ".playerbots bot add" with "character not found", not just
        -- "already in a group"). A per-name whisper "leave" can't reach a
        -- bot that doesn't exist in the world at all, so it did nothing for
        -- this case. The user confirmed in-game that a manual Disband
        -- followed by Summon/Free Roam always recovers from exactly this —
        -- so this automatically does the same thing: DisbandRoster() itself
        -- (".playerbots bot remove" broadcast, same GM-style command the
        -- button uses, then the master's own LeaveParty()) followed by
        -- ApplyMode() once that's settled, clearing any stale state
        -- server-side regardless of whether the bots are alive, offline-
        -- but-grouped, or already gone, so the rebuild always starts from a
        -- clean slate (per explicit user direction: "делай полный дисбанд и
        -- сборку нового ростера"). DisbandRoster sets mode to MODE_SOLO
        -- (that's the whole point of it — see its own doc comment), so the
        -- mode this login was actually supposed to resume in is saved here
        -- first and restored before the rebuild's ApplyMode() call, which
        -- otherwise no-ops entirely on MODE_SOLO.
        local modeToResume = NS.EffectiveMode()
        DisbandRoster()

        -- DisbandRoster's own LeaveParty() fires after STRAY_GROUP_RESET_DELAY
        -- (see its own NS.After) — wait a little past that before rebuilding,
        -- same margin ResetStrayGroups' analogous leave-then-regroup pattern
        -- uses elsewhere in this file.
        NS.After(NS.STRAY_GROUP_RESET_DELAY + 1.0, function()
            AltBot_SavedVars.mode = modeToResume
            NS.ApplyMode()
            NS.RefreshForm()
            NS.RefreshActionBar()

            -- A genuine disconnect (vs a clean /reload) can leave the server
            -- slower to settle than this first attempt accounts for — confirmed
            -- by the user in-game: after an actual disconnect, some tracked
            -- names ended up neither grouped nor re-added, and just sat there
            -- looking "left" in the party frame instead. One retry a few
            -- seconds later catches anyone MissingRosterNames still sees as
            -- absent; a no-op (GroupRoster prints nothing new) if the first
            -- attempt already got everyone.
            NS.After(6.0, function()
                if NS.EffectiveMode() ~= NS.MODE_SOLO then
                    NS.ApplyMode(nil, true)   -- silent: the mode line was already printed by the first ApplyMode
                end
            end)
        end)
    end

    -- Fire on whichever comes first: a real group-roster event (the common
    -- case — the server already has a group to report, whether that's the
    -- pre-reload group settling back in or bots the server itself restored)
    -- or a fixed fallback timeout (a genuinely empty group, e.g. fresh
    -- login/full disconnect, never fires either event, so this is what
    -- catches that case instead of waiting forever).
    rosterWaiter:SetScript("OnEvent", proceedWithLogin)
    NS.After(3.0, proceedWithLogin)
end)

-- (No "Loaded" line at startup — the single "<Mode> mode, N bot(s)." line
-- from ApplyMode is the startup message; the first-run hint to click the
-- minimap icon is printed from ApplyMode's "not configured yet" branch.)
