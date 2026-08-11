-- EbonClearance_Events - event hub + slash commands + residual glue.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Responsibility: event hub, slash commands, Bindings.xml handlers, and
-- the glue that ties Core / Companion / Protection / Vendor / Process /
-- the panel files together. ADDON_VERSION lives in this file; the
-- release workflow's sed rule (.github/workflows/release.yml) targets
-- it by filename. See docs/CODE_REVIEW.md "Resolved -> file split" for
-- the history of how this file got carved out of the original monolith.
--
-- Shared namespace for the addon. WoW passes (addonName, namespaceTable) as
-- the varargs to every .lua file in an addon; the same table is shared
-- across files. NS was first bootstrapped in Stage 1 of the file split and
-- has been the spine of every subsequent extraction. Reading or writing
-- NS.foo from any EbonClearance_*.lua file picks up the same table this
-- assignment creates. `select(2, ...)` is used instead of
-- `local addonName, NS = ...` because the main chunk is already at Lua
-- 5.1's 200-locals cap; capturing only the namespace (and not the addon
-- name string, which we don't use) spends one slot instead of two.
local NS = select(2, ...)

local ADDON_NAME = "EbonClearance"
-- TARGET_NAME / PET_NAME hold the live display names of the two Project
-- Ebonhold companion NPCs. The defaults below are the enUS strings the
-- addon shipped with; v2.9.0 made them user-configurable via DB.merchantName
-- / DB.scavengerName so a realm with a renamed or localised pet can be
-- driven without forking. EnsureDB (and EC_compCache.refreshNames for UI
-- edits) writes back into these locals every time DB is re-read, and
-- PET_NAME_LC is recomputed alongside. Companion lookup is now ID-first via the cache
-- declared in the forward-decl block; the spellID 600126 fallback in
-- FindGoblinMerchantIndex remains the safety net for first-run resolution
-- when the cache is empty AND the merchant has been renamed in DB.
local TARGET_NAME = "Goblin Merchant"
local PET_NAME = "Greedy scavenger"

-- Provenance globals (EBONCLEARANCE_* and __EbonClearance_*) plus the
-- EC_Fingerprint helper now live in EbonClearance_Core.lua per the file
-- split (Stage 2, see docs/CODE_REVIEW.md item 4). Core writes those
-- globals on load and exposes the helper as NS.Fingerprint. The byline
-- strings are read directly from NS.ADDON_AUTHOR / NS.ADDON_URL where the
-- settings byline is built (EbonClearance_MainPanel.lua).

-- Localization passthrough. NS.L is a metatable-backed table set by
-- EbonClearance_Locale.lua (loads earlier per the .toc), so it exists at
-- this file's load time. L[key] returns key unchanged unless a translation
-- exists, so wrapping player-facing strings is a no-op on the enUS client.
local L = NS.L

-- Build-time version. The release workflow's sed rule rewrites the
-- `local ADDON_VERSION = "vX.Y.Z"` line on each tag push (anchored
-- pattern fixed in v2.13.2), so the in-game UI surfaces (settings
-- panel header, bug-report builder, anything routed through EC_GetVersion)
-- always match the .toc on a release build. Dev checkouts keep
-- whatever real version the last release shipped; EC_GetVersion's
-- match check accepts any `^v%d+%.%d+%.%d+` value and short-circuits
-- to it. The fallback to GetAddOnMetadata exists for the legacy
-- placeholder case but is no longer reached on the current workflow.
-- Carrying the version here means a stale .toc cache (WoW only re-reads
-- .toc files on full client restart, not /reload) cannot make the displayed
-- version lie on a release build. The CI test in
-- tests/test_layout_reactivity.lua asserts this constant matches the
-- .toc Version field so any future drift fails CI before shipping.
-- DO NOT move this constant out of EbonClearance_Events.lua without first
-- updating the CI workflow's sed rule that targets this file by name
-- (.github/workflows/release.yml).
local ADDON_VERSION = "v2.76.0"
local function EC_GetVersion()
    -- Cached on the shared cache (not a new file-scope local) to respect
    -- the 200-locals cap on this chunk. Reached via NS.compCache because
    -- the local EC_compCache alias is declared further down the file.
    -- Version is fixed for the session.
    local cache = NS.compCache
    if not cache.cachedVersion then
        if ADDON_VERSION:match("^v%d+%.%d+%.%d+") then
            cache.cachedVersion = ADDON_VERSION
        else
            cache.cachedVersion = GetAddOnMetadata("EbonClearance", "Version") or "unknown"
        end
    end
    return cache.cachedVersion
end
-- Exposed to split files (the bug-report builder in Stage 8 reads this).
NS.GetVersion = EC_GetVersion

-- Build watermark: a precomputed fingerprint of "EbonClearance@<version>".
-- Exposed as a global so /run inspection and external auditors can read it.
-- If this exact 6-char hex value (computed for our version) ever appears in
-- another addon's source, that addon is a verbatim copy of EbonClearance.
-- Lives in this file (not Core) because it reads ADDON_VERSION, which
-- has to stay here for CI sed-rule compatibility.
_G["__EbonClearance_watermark"] = NS.Fingerprint("EbonClearance@" .. ADDON_VERSION)

local EC_GetPlayerName
local EC_IsAddonEnabledForChar

-- Cached WoW 3.3.5a API upvalues. Local lookups beat _G hash on hot paths
-- (bag scans, vendor loop, pet-check OnUpdate). See docs/ADDON_GUIDE.md.
local GetItemInfo = GetItemInfo
local GetContainerItemID = GetContainerItemID
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerNumSlots = GetContainerNumSlots
local UseContainerItem = UseContainerItem
local PickupContainerItem = PickupContainerItem
local DeleteCursorItem = DeleteCursorItem
-- Merchant API (GetMerchantNumItems / GetMerchantItemInfo / GetMerchantItemLink)
-- removed from the cached-upvalue block: not currently called on any hot path.
-- Re-add here if a future feature needs them.
local GetNumCompanions = GetNumCompanions
local GetCompanionInfo = GetCompanionInfo
local CallCompanion = CallCompanion
local IsMounted = IsMounted
local IsEquippedItem = IsEquippedItem
local UnitExists = UnitExists
local UnitName = UnitName
local GetCursorInfo = GetCursorInfo
local GetTime = GetTime
local GetUnitSpeed = GetUnitSpeed

-- Forward declarations. These must exist as upvalues before any function
-- that references them is compiled, or references inside those closures
-- resolve to _G.<name> instead of the intended local. See docs/CODE_REVIEW.md.
local STATE = {
    IDLE = "idle",
    LOOTING = "looting",
    WAITING_MERCHANT = "waiting_merchant",
    SELLING = "selling",
}
-- lootCycleState + addonDismissed + lastScavengerOut were promoted from
-- file-scope locals to EC_compCache fields (initialised in Core's table
-- literal) as part of Stage 8 prep. The cross-cutting Scavenger / cycle
-- code in this file and the bug-report builder in
-- EbonClearance_BugReport.lua now share state via the cache table.
-- Same pattern as the vendorRunning / pendingDelete promotion in Stage 5
-- and the lastScavSpokeAt promotion in Stage 3.

-- Cached companion creature IDs and v2.9.0 dismiss-vs-leash classifier state.
-- The actual table literal lives in EbonClearance_Core.lua (Stage 2 of the
-- file split, see docs/CODE_REVIEW.md item 4) and is exposed on the addon
-- namespace as NS.compCache. We re-bind it to the file-scope upvalue here
-- so every existing `EC_compCache.foo` reference downstream resolves
-- correctly without per-site changes. Same table; both names alias the
-- same memory. Comments documenting individual fields (scav, lastSummonAt,
-- bindCache, etc.) live next to the declaration in Core.
local EC_compCache = NS.compCache

-- v2.59.5 (Serv report): city zones don't count as farming areas. A player
-- vendoring mailboxed items in Dalaran / Stormwind / Orgrimmar is not
-- farming there, so their sale copper should not pollute the "Top Zones"
-- leaderboard the Stats / Stats-Guild / Stats-Server panels render.
-- Consumed by EC_compCache.attributeCopperToZone (sender-side skip),
-- the receiver-side decode filters in GuildShare / ServerShare (drop
-- city entries from peer payloads), and the EnsureDB / EnsureAccountDB
-- scrubs that strip historical city keys from DB.copperByZone and
-- ADB.accountStats.copperByZone. Wallet totalCopper is bumped
-- separately and stays accurate.
--
-- v2.59.11 (Serv report - "Fossoyeuse" appeared in Realm's Best Farming
-- Zones): the pre-fix set was enUS only. Realm-wide aggregation pools
-- from EVERY locale on the realm, so a frFR client writes "Fossoyeuse"
-- (French Undercity) into their bucket and sends it in SDAT. Our
-- English-locale receiver didn't recognize the localized name and let
-- it land on the leaderboard. Now the set covers the ten WotLK capitals
-- across enUS/enGB, deDE, frFR, and esES/esMX. Additional locales
-- (ruRU, koKR, zhCN/zhTW) can be added when reported - keeping the
-- table small until a specific locale's names show up in the wild.
local EC_CITY_ZONES_BY_LOCALE = {
    -- enUS / enGB (Project Ebonhold's primary audience)
    enUS = {
        "Stormwind City", "Ironforge", "Darnassus", "The Exodar",
        "Orgrimmar", "Thunder Bluff", "Undercity", "Silvermoon City",
        "Shattrath City", "Dalaran",
    },
    -- deDE
    deDE = {
        "Sturmwind", "Eisenschmiede", "Darnassus", "Die Exodar",
        "Orgrimmar", "Donnerfels", "Unterstadt", "Silbermond",
        "Shattrath", "Dalaran",
    },
    -- frFR
    frFR = {
        "Hurlevent", "Forgefer", "Darnassus", "L'Exodar",
        "Orgrimmar", "Les Pitons du Tonnerre", "Fossoyeuse", "Lune-d'argent",
        "Shattrath", "Dalaran",
    },
    -- esES / esMX
    esES = {
        "Ventormenta", "Forjaz", "Darnassus", "El Exodar",
        "Orgrimmar", "Cima del Trueno", "Entra\195\177as", "Lunargenta",
        "Shattrath", "Dalaran",
    },
}
local EC_CITY_ZONES = {}
for _, names in pairs(EC_CITY_ZONES_BY_LOCALE) do
    for _, name in ipairs(names) do
        EC_CITY_ZONES[name] = true
    end
end
function EC_compCache.isCityZone(zone)
    return type(zone) == "string" and EC_CITY_ZONES[zone] == true
end

-- Open the named Interface Options sub-panel. The double
-- InterfaceOptionsFrame_OpenToCategory call is the 3.3.5a quirk fix: the
-- first call only registers the category, the second actually focuses it.
-- Centralised here (on NS, so the minimap / LDB launcher reach it too)
-- rather than copy-pasted at every open site. Callers pass the global
-- frame name, e.g. "EbonClearanceOptionsMain".
function NS.OpenOptionsPanel(frameName)
    if not InterfaceOptionsFrame_OpenToCategory then
        return
    end
    local panel = _G[frameName]
    if not panel then
        return
    end
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
end
-- Player time-spent-moving (seconds) accumulated while the Scavenger is out.
-- Drives the stuck-detection heuristic in EC_HandleScavengerOut. Resets on
-- every Scavenger out<->in transition and after a stuck-dismiss fires.
local EC_scavMovementAccum = 0
-- One-shot guard: at PLAYER_ENTERING_WORLD (post-/reload, post-zone) we scan
-- the companion list once to bootstrap EC_lastScavengerOut. Without this the
-- gate above stays false until the first 5 s tick observes the state, which
-- eats ~5 s of accumulation if the Scavenger was already out at /reload.
local EC_scavStateBootstrapped = false
-- Last GetTime() at which we observed the Scavenger speak (matched in
-- EC_GreedyEventFilter, either by author or by the textual fallback). Drives
-- the loot-silence stuck signal: if the player has looted N+ corpses inside
-- the window without the Scavenger speaking, the pet is presumed lost
-- out-of-range and the addon dismisses-then-resummons. Updated only while
-- DB.autoLootCycle is on, so users not running the cycle pay no extra work
-- on the chat-event path. Lives on EC_compCache (declared in
-- EbonClearance_Core.lua) so EbonClearance_Companion.lua's chat filter and
-- EbonClearance_Events.lua's EC_IsLootSilenceStuck can both access it via the
-- shared cache table after the file split. See docs/CODE_REVIEW.md item 4.
-- Ring of GetTime() values pushed on every LOOT_CLOSED (player corpse loot
-- completed). Pruned in place inside EC_IsLootSilenceStuck on each pet-tick
-- check, so it cannot grow unboundedly across a session.
local EC_recentLootTimes = {}

-- v2.65.1 (Serv report - rough-terrain farming spammed the chat with
-- "went quiet" / "resummoned" every 10-15 s while the recovery loop
-- correctly dismissed + re-summoned a stuck pet). The recovery MECHANIC
-- is legitimate; the spam is what makes it read as "lots of problems".
-- Rate-limit the announce to at most one pair (went quiet -> resummoned)
-- per EC_RECOVERY_ANNOUNCE_COOLDOWN seconds. Subsequent stuck-signal
-- dismiss+resummons within the cooldown still happen, just silently.
-- Counter + last-fire timestamp surface in /ec bugreport so a session's
-- actual recovery cadence stays visible without chat noise.
--
-- EC-TRAP: state stored on EC_compCache (not as file-locals) because
-- EbonClearance_Events.lua is already at the 200-local cap; every new
-- local here throws "too many local variables in main function" at
-- luac. Same reason a few other counters live on EC_compCache.
EC_compCache.scavRecoveryFires = 0
EC_compCache.lastScavRecoveryAt = 0
EC_compCache.lastScavRecoveryAnnounceAt = 0
EC_compCache.scavRecoveryAnnounceCooldown = 60

-- Accessor for /ec bugreport. Returns the current session count + the
-- absolute GetTime() the last recovery fired (0 if none yet).
NS.GetScavRecoveryStats = function()
    return EC_compCache.scavRecoveryFires, EC_compCache.lastScavRecoveryAt
end
-- v2.9.0 manual-sell attribution. inSelfSell brackets every UseContainerItem
-- call DoNextAction makes so the hooksecurefunc bound at ADDON_LOADED skips
-- it (counters are bumped directly by the worker queue). snapshot is a
-- slot -> { link, count, itemID } map taken at MERCHANT_SHOW and refreshed
-- per-slot after every observed sell; the hook reads it to identify what
-- just left a bag slot once the slot is empty.
local EC_manualSell = {
    inSelfSell = false,
    snapshot = {},
    hookInstalled = false,
}
-- vendorRunning state was promoted from `local running = false` to
-- EC_compCache.vendorRunning (initialised in EbonClearance_Core.lua's
-- table literal) so EbonClearance_Vendor.lua can write it and the
-- non-vendor handlers in this file can read it via the shared cache
-- table after the Stage 5 file split.

-- The Greedy Scavenger chat filter, the speech-bubble killer, and
-- the secondary ApplyGreedyChatFilter live in EbonClearance_Companion.lua
-- (Stage 3 of the file split, see docs/CODE_REVIEW.md item 4). Companion
-- exposes NS.InstallGreedyMuteOnce and NS.ApplyGreedyChatFilter, which
-- the event hub + ADDON_LOADED branch + DB toggles further down this
-- file call by name.

-- Forward-declared so EC_AddItemToList (defined below) can call it before the
-- helper body is reached further down the file. Returns the name of a list
-- that already holds the item with a different intent (keep / sell / delete),
-- or nil when the add is safe. Same-intent scopes (character whitelist plus
-- account whitelist) do not conflict.
local EC_FindAddConflict

-- v2.51.0: forward-declare the diagnostic-hook helpers so hook sites
-- above their definitions can call them. Each helper is a session-local
-- ring-buffer / snapshot / timestamp appender consumed by
-- /ec bugreport. Bodies are assigned further down the file next to the
-- ring buffer they own. Without the forward-declare, load-time
-- resolution would bind these names to (nil) globals - the runtime
-- error "attempt to call global 'EC_StampEvent' (a nil value)" v2.51.0
-- initially shipped with, before this fix.
local EC_LogSilentRefusal
local EC_LogRecentSold
local EC_LogRecentDeleted
local EC_StampEvent

-- Forward-declared on NS so the Character Settings panel's toggle +
-- colour-picker closures can call it before the bag-display hooks (which
-- own the body) install. Stub-assigned to a no-op here so settings flips
-- work even before the hooks register. The real body is assigned by
-- EbonClearance_BagDisplay.lua (Stage 6 of the file split, see
-- docs/CODE_REVIEW.md item 4). Lives on NS rather than as a file-scope
-- local because the body assignment is in a different file post-Stage-6;
-- a `local` here would mean BagDisplay's assignment creates a global
-- instead of replacing the stub. Callers reach it as NS.RefreshSellBorders.
NS.RefreshSellBorders = function() end

local PET_NAME_LC = PET_NAME:lower()
-- Initial namespace exposure (before EnsureDB runs). EnsureDB and
-- EC_compCache.refreshNames rewrite these once the saved DB names are
-- known. Split files (Companion) read NS.PET_NAME_LC inline at call time
-- so they always see the current value.
NS.PET_NAME = PET_NAME
NS.TARGET_NAME = TARGET_NAME
NS.PET_NAME_LC = PET_NAME_LC

-- ===========================================================================
-- Per-character partition (v2.34.x migration).
-- ---------------------------------------------------------------------------
-- The .toc declares `## SavedVariables: EbonClearanceDB, EbonClearanceAccountDB`
-- which makes BOTH tables account-wide. Prior to this migration the
-- documented "per-character" semantics for the lists / profiles / per-mode
-- preferences were silently account-wide; every character on the account
-- shared the same Keep List, Sell List, Delete List, profile catalogue,
-- and the Process Bags ignore / collapsed-section state. Reported in-game
-- as the auto-Keep-equipped tag leaking onto a freshly-logged alt that
-- had never worn the item.
--
-- Fix without a .toc-directive change (which would risk cross-character
-- data loss because WoW serializes per-saved-variable-name): partition
-- inside the existing account-wide table.
--
--   * Top-level `EbonClearanceDB.<field>` stays as the legacy snapshot.
--     Reads / writes from current code never go here (the proxy routes
--     PER_CHAR_FIELDS to the per-character namespace). The snapshot is
--     the seed for newly-migrated characters AND the downgrade safety
--     net: a v2.33.x-or-earlier client looking for `DB.blacklist` etc.
--     still finds its pre-migration baseline at the top level.
--   * `EbonClearanceDB.chars[charKey]` holds each character's live data.
--     Each character gets a deep-copy of the snapshot on first load with
--     the new schema, then diverges from there.
--   * `DB` is a metatable proxy: PER_CHAR_FIELDS route to
--     `chars[charKey]`, everything else routes to the top level.
--
-- Test 66 in tests/test_perf_guardrails.lua locks the structural
-- invariants of this partition.
local PER_CHAR_FIELDS = {
    -- v2.75.0 (fresh-audit fix): the master Enable/Disable flag. The README,
    -- the panel checkbox, and /ec enable|disable have always described this as
    -- per-character ("skip the addon on alts"), but the flag was routed to the
    -- account-wide top level, so disabling on one alt disabled every character.
    -- Making it per-character matches the documented behaviour. Existing saves
    -- migrate: a character namespace that predates this seeds `enabled` from the
    -- frozen account-wide value (see the seed block in EnsureDB), so a player
    -- who had EC disabled account-wide is never silently re-enabled.
    enabled = true,
    blacklist = true,
    blacklistAuto = true,
    whitelist = true,
    deleteList = true,
    whitelistProfiles = true,
    blacklistProfiles = true,
    activeProfileName = true,
    processIgnored = true,
    processCollapsedModes = true,
    -- v2.62.0 per-skill Process Bags toggles ({ mode = bool }, default-on).
    -- Per-character because professions vary by alt (mirrors the
    -- processCollapsedModes / processIgnored precedent).
    processEnabledModes = true,
    -- v2.35.x gold-per-hour stats. bestGPH stores the highest sustained
    -- session GPH (copper/hour) the character has reached; bestGPHAt is
    -- the wall-clock timestamp via `time()` so the panel can render a
    -- humanised "N days ago" / absolute-date string; bestGPHZone is the
    -- GetRealZoneText snapshot at the moment the best was set. All
    -- three are written atomically by the RefreshStats best-update
    -- gate (5-minute minimum session). See
    -- docs/specs/2026-05-26-gph-stats-design.md.
    bestGPH = true,
    bestGPHAt = true,
    bestGPHZone = true,
    -- Per-character loot ledger (itemID -> total quantity looted by this
    -- character, persisted). The Loot Log's Character scope reads this; the
    -- account-wide aggregate lives in ADB.accountStats.lootedItemCounts and
    -- the live session view in the in-memory EC_lootSession.
    lootedItemCounts = true,
    -- v2.36.x Help / FAQ panel per-section collapse state. Stored
    -- per-character so each character can independently choose which
    -- sections (troubleshooting / gates / labels) are expanded vs
    -- collapsed. Matches the processCollapsedModes precedent. See
    -- docs/specs/2026-05-26-help-faq-panel-design.md.
    helpSectionsCollapsed = true,
    -- v2.72.0 settings profiles: WHICH settings profile this character
    -- uses. The profile BODIES live at the top-level
    -- EbonClearanceDB.settingsProfiles[name] (account-wide, so alts can
    -- share one by pointing at it); only the pointer is per-character.
    activeSettingsProfile = true,
}

-- v2.72.0 settings profiles: the selling-behaviour fields that live in a
-- named settings profile instead of the account-wide top level. The DB
-- proxy routes reads/writes of these through the character's active
-- profile (see EC_DBBuildProxy), so every existing `DB.<field>` call
-- site - panels, the decision core, the vendor cycle - works unchanged.
-- Scope decision (Serv, 2026-07-30): selling behaviour + vendor-visit
-- actions + pacing ONLY. Master enable, looting/scavenger behaviour,
-- visual preferences, locale, lists, and stats stay account-wide or
-- per-character exactly as before.
-- Top-level copies of these fields freeze at migration time as the
-- downgrade safety net + the seed for the "Default" profile (the same
-- model PER_CHAR_FIELDS established in v2.34).
-- Hangs off EC_compCache (not a main-chunk local): the Events main
-- chunk is AT the 200-locals cap.
EC_compCache.settingsProfileFields = {
    -- merchant / rules
    merchantMode = true,
    qualityRules = true,
    -- deletion + auto-mark
    enableDeletion = true,
    autoDeleteOnPickup = true,
    autoDeleteGreyOnLoot = true,
    announceAutoDelete = true,
    announceAutoDeleteQualities = true,
    autoMarkResilience = true,
    autoMarkAffixDupes = true,
    autoMarkKnownUnsellableRecipes = true,
    automarkProtectHighILvl = true,
    -- protections
    protectAffixedRareItems = true,
    protectChanceOnHitItems = true,
    sellChanceOnHitKnown = true,
    protectUnlearnedTomes = true,
    protectAllTomes = true,
    autoAddEquipped = true,
    autoProtectUpgrades = true,
    autoProtectEquipmentSets = true,
    -- affix rules
    affixAllowExactDupes = true,
    affixMinSellRank = true,
    keepBoeAffixDupes = true,
    keepBoeBelowRankFloor = true,
    -- recipes
    sellKnownRecipes = true,
    sellKnownRecipeQualities = true,
    sellKnownRecipeBindFilter = true,
    -- vendor-visit actions + pacing
    repairGear = true,
    repairUseGuildBank = true,
    vendorInterval = true,
    maxItemsPerRun = true,
    fastMode = true,
    turboMode = true,
}

local function EC_DBCharKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

local function EC_DBDeepCopy(t)
    if type(t) ~= "table" then
        return t
    end
    local c = {}
    for k, v in pairs(t) do
        c[k] = EC_DBDeepCopy(v)
    end
    return c
end

local function EC_DBBuildProxy(charNamespace)
    local SPF = EC_compCache.settingsProfileFields
    -- Resolve this character's settings-profile body. Falls back to
    -- "Default" when the pointer names a profile that no longer exists
    -- (safety net; the delete path also repoints stale pointers), and
    -- to nil pre-migration so the read drops through to the top-level
    -- legacy values.
    local function activeSettings()
        local profiles = rawget(EbonClearanceDB, "settingsProfiles")
        if not profiles then
            return nil
        end
        return profiles[charNamespace.activeSettingsProfile or "Default"] or profiles.Default
    end
    return setmetatable({}, {
        __index = function(_, k)
            if PER_CHAR_FIELDS[k] then
                return charNamespace[k]
            end
            if SPF[k] then
                local p = activeSettings()
                if p then
                    local v = p[k]
                    if v ~= nil then
                        return v
                    end
                    -- v2.75.0 (fresh-audit fix): the active profile exists but
                    -- lacks this field (a settings-profile field added AFTER the
                    -- profile was created - the "future-field trap"). Fall
                    -- through to the frozen top-level legacy value instead of
                    -- returning nil, matching the pre-migration fallback the
                    -- design intended. EnsureDB then writes the nil-default back
                    -- into the profile through __newindex on its next pass.
                end
            end
            return rawget(EbonClearanceDB, k)
        end,
        __newindex = function(_, k, v)
            if PER_CHAR_FIELDS[k] then
                charNamespace[k] = v
                return
            end
            if SPF[k] then
                local p = activeSettings()
                if p then
                    p[k] = v
                    return
                end
            end
            rawset(EbonClearanceDB, k, v)
        end,
    })
end

local DB
-- Account-wide SavedVariable. Holds a single `whitelist` table that unions with
-- the per-character whitelist at sell time. Bootstrapped by EnsureAccountDB().
local ADB

-- Resolves list names (used by CreateListUI) to the underlying table. Extra
-- scopes (e.g. account whitelist) register themselves here so CreateListUI can
-- render them without knowing about the scope.
local EC_ExtraListTables = {}

local function EC_GetListTable(name)
    local extra = EC_ExtraListTables[name]
    if extra ~= nil then
        return extra
    end
    return DB and DB[name]
end
NS.GetListTable = EC_GetListTable

local function EnsureAccountDB()
    if EbonClearanceAccountDB == nil then
        EbonClearanceAccountDB = {}
    end
    ADB = EbonClearanceAccountDB
    -- Mirror the live ADB binding onto the namespace so split files (post-
    -- Stage 3) can read NS.ADB inline at call time. Same table; both
    -- names alias the same memory. See docs/CODE_REVIEW.md item 4.
    NS.ADB = ADB
    if type(ADB.whitelist) ~= "table" then
        ADB.whitelist = {}
    end
    EC_ExtraListTables["accountWhitelist"] = ADB.whitelist
    -- v2.26.0 / v2.27.0: account-wide override list for the v2.20.0
    -- chance-on-hit protection AND the v2.23.0 random-affix
    -- protection. Marking an itemID releases the safety net so
    -- future drops auto-sell via the normal quality rules and
    -- become eligible for Process Bags. Account-wide because both
    -- PE's affix / proc extractions are themselves account-wide and
    -- whether to keep / sell a protected item is an item-property
    -- decision, not a per-character one.
    --
    -- Migrated from the v2.26.0 `allowedProcs` field. New name
    -- (`allowedItems`) reflects that the list now covers both
    -- protection mechanisms; the old name was misleading for
    -- affixed items. One-shot migration: contents move across,
    -- the old field clears.
    if type(ADB.allowedItems) ~= "table" then
        ADB.allowedItems = {}
    end
    -- v2.27.0: affix-keyed allow list. Random-affix items carry their
    -- identity in the affix description (per-instance roll), so a
    -- per-itemID mark is too coarse - it'd let every base-itemID drop
    -- through regardless of which affix rolled. This list is keyed by
    -- the normalised affix description (same key the v2.23.0
    -- knownAffixDescriptions set uses), so marking one drop allows
    -- every future drop rolling the same affix even across different
    -- base items.
    if type(ADB.allowedAffixes) ~= "table" then
        ADB.allowedAffixes = {}
    end
    -- One-shot migration: case-fold existing keys to match the post-fix
    -- normaliser. Prior to this version the normaliser preserved source
    -- casing, so entries stored from a description that began with a
    -- capital letter would no longer match a lookup that now produces
    -- a lowercase key. Walk the table, lowercase any key that isn't
    -- already pure-lower, and carry the value across. Idempotent on
    -- subsequent loads (lowercased keys equal their own lowered form).
    do
        local migrated, remapped = false, {}
        for k, v in pairs(ADB.allowedAffixes) do
            if type(k) == "string" then
                local lk = k:lower()
                if lk ~= k then
                    -- Keep-first on a case collision: don't clobber an entry
                    -- that already exists under the lowercase key (values are
                    -- membership flags, so the surviving key preserves the mark
                    -- either way). The mixed-case key is dropped regardless.
                    if remapped[lk] == nil and ADB.allowedAffixes[lk] == nil then
                        remapped[lk] = v
                    end
                    ADB.allowedAffixes[k] = nil
                    migrated = true
                end
            end
        end
        if migrated then
            for k, v in pairs(remapped) do
                ADB.allowedAffixes[k] = v
            end
        end
    end
    -- v2.27.0: side meta marking which Sell/Keep/Delete list entries
    -- came in via an affixed-item menu add. Lets the list panels
    -- render an "(affix-gated)" tag on those rows so the user knows
    -- the entry doesn't blanket-sell every drop of that itemID -
    -- the affix protection still filters per-drop. Account-scoped
    -- because the affix-ness of an itemID is an item property
    -- (random-suffix DBC field), not a per-character thing.
    if type(ADB.affixedListedItems) ~= "table" then
        ADB.affixedListedItems = {}
    end
    -- v2.37.0: parallel meta to affixedListedItems, but for chance-on-
    -- hit proc items. Stamped at list-add time and during the tooltip
    -- backfill in EC_AnnotateTooltip so the list panels can render a
    -- "(Hit-proc)" tag on rows whose base itemID carries a proc -
    -- reminds the user that the chance-on-hit protection still applies
    -- per-drop even though the base itemID is on a list. Account-
    -- scoped because the chance-on-hit flag is an item property (same
    -- shape as affixedListedItems above).
    if type(ADB.chanceOnHitListedItems) ~= "table" then
        ADB.chanceOnHitListedItems = {}
    end
    -- v2.37.0 (Borrow A): defaults for the affix-pipeline event logger.
    -- affixDebugEnabled stays nil until the player runs /ec affixdebug
    -- on (treated as "off" by every read site). affixDebugMaxRows is
    -- seeded so a player who wants to capture a long session can edit
    -- the SV directly to lift the cap without having to discover the
    -- nil-default via reading source. The runtime clamps to >= 100 so
    -- a corrupt low value can't render the log useless. affixDebug
    -- (the row table itself) is lazy - only allocated when a probe
    -- fires while the flag is on.
    if type(ADB.affixDebugMaxRows) ~= "number" or ADB.affixDebugMaxRows < 100 then
        ADB.affixDebugMaxRows = 1000
    end
    -- v2.46.x: Loot Log per-item hide set (itemID -> true). A display-only
    -- filter so high-volume low-interest drops (e.g. cloth) can be hidden so
    -- they stop skewing the share percentages; hidden items are excluded from
    -- both the list AND the totals so remaining shares rebase. Account-wide
    -- because it's a display preference, not character data. Cleared by the
    -- Loot Log's "Unhide All" button.
    if type(ADB.lootLogHidden) ~= "table" then
        ADB.lootLogHidden = {}
    end
    -- v2.49.0: chance-on-hit procLine -> PE spellID map, populated by the
    -- on-the-fly autolearn (bag-diff snapshot + LEARNED_SPELL_IN_TAB
    -- handler). Complements the hardcoded EC_CHANCE_PROC_KEYWORDS seed
    -- map: seed catches common procs by keyword, autolearn catches the
    -- exact procLine each item ships with. Account-wide because
    -- extraction state is account-wide. Key: verbatim item procLine
    -- string. Value: PE affix spell ID (700xxx range).
    if type(ADB.chanceProcMap) ~= "table" then
        ADB.chanceProcMap = {}
    end
    -- v2.49.1: itemID -> {spellID, family, item, learnedAt} pairings
    -- autolearned via LEARNED_SPELL_IN_TAB correlation. Written when
    -- exactly one unmapped chance-on-hit weapon disappeared from bags
    -- in the recent window and a new PE 700xxx spell was learned.
    if type(ADB.chanceProcConfirmedItems) ~= "table" then
        ADB.chanceProcConfirmedItems = {}
    end
    -- v2.49.1: array of correlation-failed events. When
    -- LEARNED_SPELL_IN_TAB fires and MULTIPLE unmapped chance-on-hit
    -- weapons had disappeared from bags in the recent window, we can't
    -- correlate 1:1 - save all candidates + the new spell for review
    -- via /ec autolearnpeek. Never auto-promoted.
    if type(ADB.chanceProcAmbiguous) ~= "table" then
        ADB.chanceProcAmbiguous = {}
    end
    -- v2.38.1: account-wide stats ledger. Every per-character stat write
    -- mirrors into ADB.accountStats so the Stats panel's Account view
    -- aggregates totals across all characters. Counts forward from
    -- v2.38.1 install (no backfill from existing DB.* fields). The
    -- panel surfaces `startedAt` in a one-liner so the user understands
    -- the account ledger may have started after their per-character
    -- history.
    if type(ADB.accountStats) ~= "table" then
        ADB.accountStats = {}
    end
    local AS = ADB.accountStats
    if type(AS.totalCopper) ~= "number" then
        AS.totalCopper = 0
    end
    if type(AS.totalItemsSold) ~= "number" then
        AS.totalItemsSold = 0
    end
    if type(AS.totalItemsDeleted) ~= "number" then
        AS.totalItemsDeleted = 0
    end
    if type(AS.totalRepairs) ~= "number" then
        AS.totalRepairs = 0
    end
    if type(AS.totalRepairCopper) ~= "number" then
        AS.totalRepairCopper = 0
    end
    if type(AS.soldItemCounts) ~= "table" then
        AS.soldItemCounts = {}
    end
    if type(AS.deletedItemCounts) ~= "table" then
        AS.deletedItemCounts = {}
    end
    if type(AS.soldItemsByQuality) ~= "table" then
        AS.soldItemsByQuality = {}
    end
    if type(AS.soldCopperByQuality) ~= "table" then
        AS.soldCopperByQuality = {}
    end
    if type(AS.deletedItemsByQuality) ~= "table" then
        AS.deletedItemsByQuality = {}
    end
    if type(AS.processCastCounts) ~= "table" then
        AS.processCastCounts = {}
    end
    if type(AS.copperByZone) ~= "table" then
        AS.copperByZone = {}
    end
    -- v2.59.5 (Serv report): scrub city-zone entries from the account-
    -- wide bucket.
    -- v2.59.10 (bug-hunt): removed the one-shot marker gate, same
    -- rationale as the DB scrub above - self-heal a downgrade -> upgrade
    -- cycle that would leave the marker true while re-poisoning the
    -- account bucket via the intermediate version.
    for zone in pairs(EC_CITY_ZONES) do
        AS.copperByZone[zone] = nil
    end
    ADB.cityZonesScrubbed = true
    -- Session loot tracker, account-wide running total. Keyed by itemID ->
    -- total quantity looted across all characters since install. Aggregate
    -- only (one integer per distinct item), so it stays bounded. The live
    -- session view is held in memory (NS.lootSession); this is the
    -- persisted side the loot window's Account scope reads.
    if type(AS.lootedItemCounts) ~= "table" then
        AS.lootedItemCounts = {}
    end
    if type(AS.bestGPH) ~= "number" then
        AS.bestGPH = 0
    end
    if type(AS.bestGPHAt) ~= "number" then
        AS.bestGPHAt = 0
    end
    if type(AS.bestGPHZone) ~= "string" then
        AS.bestGPHZone = ""
    end
    if type(AS.bestGPHChar) ~= "string" then
        AS.bestGPHChar = ""
    end
    if type(AS.startedAt) ~= "number" then
        AS.startedAt = time()
    end
    -- One-shot migration from the v2.26.0 field `allowedProcs`.
    -- rawget avoids the EnsureDefaults pattern's auto-create when
    -- the legacy field has already been migrated away.
    local legacy = rawget(ADB, "allowedProcs")
    if type(legacy) == "table" then
        for k, v in pairs(legacy) do
            ADB.allowedItems[k] = v
        end
        ADB.allowedProcs = nil
    end
end

local function EnsureDB()
    -- Fresh-install detection. We're a fresh install only if neither the
    -- current SavedVariable nor the legacy EbonholdStuff one existed
    -- before this session. Captured BEFORE the rename migration below
    -- so an EbonholdStuff upgrader doesn't get treated as fresh and
    -- have ON-by-default fields enabled without consent. Drives the
    -- "default autoAddEquipped ON for new installs only" rule below.
    local isFreshInstall = (EbonClearanceDB == nil) and (EbonholdStuffDB == nil)

    -- Legacy-rename migration. MUST run before field defaults below, because
    -- the profile-migration block (further down) reads existing DB.whitelist
    -- to decide whether to snapshot it into an "Imported" profile. If field
    -- defaults ran first, DB.whitelist would be {}, and any data the user
    -- had under the old EbonholdStuffDB name would be lost. Order-dependent.
    if EbonholdStuffDB and not EbonClearanceDB then
        EbonClearanceDB = EbonholdStuffDB
        EbonholdStuffDB = nil
    end
    if EbonClearanceDB == nil then
        EbonClearanceDB = {}
    end
    -- Version-update nudge (opt-out, default ON). Account-level: a single
    -- toggle that also gates all addon-message comms in this release.
    if EbonClearanceDB.versionAlerts == nil then
        EbonClearanceDB.versionAlerts = true
    end
    -- Guild farming/stats sharing (opt-in, default OFF). Account-level.
    if EbonClearanceDB.shareGuildData == nil then
        EbonClearanceDB.shareGuildData = false
    end
    -- Show player name with shared data (opt-in, default OFF). Account-level.
    if EbonClearanceDB.shareGuildName == nil then
        EbonClearanceDB.shareGuildName = false
    end
    -- v2.53.0: Chance-on-hit proc-pairing sharing (opt-in, default OFF).
    -- Account-level because the underlying knowledge base
    -- (ADB.chanceProcConfirmedItems) is account-wide.
    if EbonClearanceDB.shareChanceProcs == nil then
        EbonClearanceDB.shareChanceProcs = false
    end
    -- v2.58.0 introduced this as opt-in default OFF. v2.59.1 flips the default
    -- to ON, plus a one-time migration bump for existing users so the change
    -- reaches every session, not just fresh installs.
    --
    -- shareServerData feeds the anonymous "Stats - Server" odometer AND is what
    -- lets you see it (it shows no names, so there is no name-sharing toggle).
    -- Turning it on is also what joins the hidden realm channel; a channel slot
    -- is never used otherwise. Realm-wide version alerts ride that same channel
    -- (the existing versionAlerts nudge hears realm versions when you're
    -- sharing), so there is no separate realm-update toggle.
    --
    -- shareServerDataDefaultBumped is the one-shot migration marker. Once set
    -- (either via the fresh-install seed below OR via the v2.59.1 one-time
    -- bump), the shareServerData value is never touched by EnsureDB again -
    -- the user can turn it off in the panel afterwards and it stays off.
    if EbonClearanceDB.shareServerData == nil then
        -- Fresh install (or first login after v2.59.1 for a character that
        -- never saw v2.58.0). Seed ON.
        EbonClearanceDB.shareServerData = true
        EbonClearanceDB.shareServerDataDefaultBumped = true
    elseif EbonClearanceDB.shareServerDataDefaultBumped ~= true then
        -- Existing user with the v2.58.0 default-off seed still stored.
        -- One-time bump to true, then set the marker so future logins do not
        -- override any subsequent user choice.
        EbonClearanceDB.shareServerData = true
        EbonClearanceDB.shareServerDataDefaultBumped = true
    end
    -- Language override (default false = follow the client's GetLocale()).
    -- Account-level. A locale code ("frFR" / "deDE" / ...) forces that
    -- language regardless of the client; false / "auto" follows the client.
    -- Applied to the locale layer here so it is live for everything looked up
    -- after login (a /reload refreshes the few strings captured at file load).
    if EbonClearanceDB.localeOverride == nil then
        EbonClearanceDB.localeOverride = false
    end
    if NS.SetLocaleOverride then
        NS.SetLocaleOverride(EbonClearanceDB.localeOverride)
    end

    -- Per-character partition (v2.34.x). See the PER_CHAR_FIELDS block at
    -- the top of the file for the rationale. Top-level fields remain as
    -- the legacy snapshot (downgrade safety + migration seed); each
    -- character's live data lives at EbonClearanceDB.chars[charKey].
    if EbonClearanceDB.chars == nil then
        EbonClearanceDB.chars = {}
    end
    local charKey = EC_DBCharKey()
    -- Guard: at a very early ADDON_LOADED, UnitName("player") /
    -- GetRealmName() can still be nil, making the key "Unknown-...". Never
    -- persist a partition under that key (it would be an orphan namespace
    -- in SavedVariables, one per fresh account); bind a transient in-memory
    -- namespace instead. The PLAYER_LOGIN EnsureDB re-run resolves the real
    -- key and rebinds to the persisted partition, so nothing written before
    -- login can land on an orphan.
    local charNSIsTransient = charKey:find("^Unknown%-") ~= nil
    if charNSIsTransient then
        EC_compCache.unknownCharNS = EC_compCache.unknownCharNS or {}
    elseif not EbonClearanceDB.chars[charKey] then
        local charNS = {}
        for k in pairs(PER_CHAR_FIELDS) do
            if EbonClearanceDB[k] ~= nil then
                charNS[k] = EC_DBDeepCopy(EbonClearanceDB[k])
            end
        end
        EbonClearanceDB.chars[charKey] = charNS
    end

    -- v2.34.x cleanup pass for the cross-character auto-Keep leak.
    -- ----------------------------------------------------------------
    -- The initial per-character migration above deep-copies the entire
    -- legacy snapshot into every newly-migrated character's namespace.
    -- That preserves manual user adds (Sell / Keep / Delete lists)
    -- correctly, but it also carries forward AUTO-added entries that
    -- were stamped by some OTHER character during the pre-migration
    -- account-wide period: equipped gear, upgrade detections, equipment-
    -- set items. Symptom in-game: the main character picks up an item
    -- only the alt has ever worn and the tooltip still says
    -- "Keep (equipped)" because the legacy auto-tag is on this
    -- character's namespace too.
    --
    -- Fix: drop blacklist + blacklistAuto entries that appear in the
    -- LEGACY snapshot's blacklistAuto map (top-level, frozen). Those
    -- are by definition auto-added pre-migration. Manual blacklist
    -- entries (no blacklistAuto tag) are preserved.
    --
    -- The live auto-protect paths (PLAYER_EQUIPMENT_CHANGED ->
    -- protectEquipSlot, checkBagsForUpgrades, EQUIPMENT_SETS_CHANGED)
    -- will repopulate this character's tags authentically under their
    -- own login. To make that immediate for currently-equipped gear,
    -- arm pendingFreshInstallSync so PLAYER_LOGIN runs syncEquipped
    -- after a 2 s settle.
    --
    -- Gate via `_migratedV2` so the cleanup runs exactly once per
    -- character; otherwise a subsequent /reload would re-drop entries
    -- the live paths just re-added.
    local charNS = charNSIsTransient and EC_compCache.unknownCharNS or EbonClearanceDB.chars[charKey]
    if not charNS._migratedV2 then
        local legacyAuto = EbonClearanceDB.blacklistAuto
        if type(legacyAuto) == "table" then
            if type(charNS.blacklist) == "table" then
                for id in pairs(legacyAuto) do
                    charNS.blacklist[id] = nil
                end
            end
            if type(charNS.blacklistAuto) == "table" then
                for id in pairs(legacyAuto) do
                    charNS.blacklistAuto[id] = nil
                end
            end
        end
        charNS._migratedV2 = true
        if EbonClearanceDB.autoAddEquipped then
            EC_compCache.pendingFreshInstallSync = true
        end
    end

    -- v2.75.0 (fresh-audit fix): `enabled` became a PER_CHAR_FIELDS field. A
    -- character namespace created before this change has no `enabled` key, so
    -- the proxy would read nil and EnsureDB would default it to true - silently
    -- re-enabling a player who had EbonClearance disabled account-wide. Seed it
    -- once from the frozen top-level (account-wide) value so that state carries
    -- across per character. Newly-migrated / fresh characters were already
    -- seeded by the PER_CHAR_FIELDS copy loop above; this only fills the gap for
    -- namespaces that predate the field.
    if charNS.enabled == nil and type(EbonClearanceDB.enabled) == "boolean" then
        charNS.enabled = EbonClearanceDB.enabled
    end

    -- v2.72.0 settings-profile migration. Runs BEFORE the proxy build so
    -- it reads the RAW top-level values. One-shot seed: the "Default"
    -- profile is a deep copy of the current account-wide selling
    -- settings, and every character starts pointed at it - zero
    -- behaviour change on upgrade. The top-level copies freeze from here
    -- on (downgrade safety net, same model as the v2.34 partition); all
    -- live reads/writes route through the proxy into the active profile.
    -- Fresh installs seed an empty Default that the nil-default blocks
    -- below fill through the proxy.
    if type(EbonClearanceDB.settingsProfiles) ~= "table" then
        EbonClearanceDB.settingsProfiles = {}
    end
    if type(EbonClearanceDB.settingsProfiles.Default) ~= "table" then
        local def = {}
        for f in pairs(EC_compCache.settingsProfileFields) do
            if EbonClearanceDB[f] ~= nil then
                def[f] = EC_DBDeepCopy(EbonClearanceDB[f])
            end
        end
        EbonClearanceDB.settingsProfiles.Default = def
    end
    if type(charNS.activeSettingsProfile) ~= "string" then
        charNS.activeSettingsProfile = "Default"
    end

    -- DB is a metatable proxy so existing call sites (`DB.foo`) keep
    -- working unchanged. Per-character fields route to chars[charKey];
    -- settings-profile fields route to the character's active settings
    -- profile; everything else stays on the top-level (account-wide) table.
    DB = EC_DBBuildProxy(charNS)
    -- Mirror the live DB binding onto the namespace so split files can
    -- read NS.DB inline at call time. Same proxy; both names alias it.
    -- EnsureAccountDB() below does the same for ADB. See
    -- docs/CODE_REVIEW.md item 4.
    NS.DB = DB
    EnsureAccountDB()

    if type(DB.lootedItemCounts) ~= "table" then
        DB.lootedItemCounts = {}
    end
    if type(DB.deleteList) ~= "table" then
        DB.deleteList = {}
    end
    if type(DB.allowedChars) ~= "table" then
        DB.allowedChars = {}
    end

    if type(DB.totalCopper) ~= "number" then
        DB.totalCopper = 0
    end

    if type(DB.totalItemsSold) ~= "number" then
        DB.totalItemsSold = 0
    end
    if type(DB.totalItemsDeleted) ~= "number" then
        DB.totalItemsDeleted = 0
    end
    if type(DB.totalRepairs) ~= "number" then
        DB.totalRepairs = 0
    end
    if type(DB.totalRepairCopper) ~= "number" then
        DB.totalRepairCopper = 0
    end

    if type(DB.soldItemCounts) ~= "table" then
        DB.soldItemCounts = {}
    end
    if type(DB.deletedItemCounts) ~= "table" then
        DB.deletedItemCounts = {}
    end

    -- v2.37.0: per-quality breakdown of lifetime sells. Keyed by item
    -- rarity (0=Poor through 7=Heirloom). Captured at the sell-success
    -- site in both the manual (UseContainerItem hook) and worker
    -- (auto-cycle) paths so the Stats panel can render a "Sold by
    -- Quality" rollup. Counts are stack-event counts (matching
    -- DB.totalItemsSold / DB.soldItemCounts semantics for the
    -- respective path), copper is summed per-event.
    if type(DB.soldItemsByQuality) ~= "table" then
        DB.soldItemsByQuality = {}
    end
    if type(DB.soldCopperByQuality) ~= "table" then
        DB.soldCopperByQuality = {}
    end
    -- v2.37.x: per-quality breakdown of lifetime deletions. Mirrors
    -- soldItemsByQuality but keyed by item rarity. Stamped at the
    -- worker delete-action site (Delete-List auto-deletions). No
    -- copper field - deletion produces no money.
    if type(DB.deletedItemsByQuality) ~= "table" then
        DB.deletedItemsByQuality = {}
    end
    -- v2.37.0: Process Bags lifetime cast counters. Keyed by the
    -- localised spell name UNIT_SPELLCAST_SUCCEEDED emits ("Disenchant",
    -- "Milling", "Prospecting", "Pick Lock"). Counts EVERY successful
    -- cast of these spells - both Process Bags-driven and manual
    -- casts. "Opening" is excluded (fires on every right-click box
    -- open, which would over-attribute).
    if type(DB.processCastCounts) ~= "table" then
        DB.processCastCounts = {}
    end
    -- v2.37.0: lifetime gold earned per zone. Keyed by the localised
    -- GetRealZoneText string at sell time (or "Unknown" when the zone
    -- text isn't available, e.g. mid-load). Both the manual sell hook
    -- and the worker-cycle FinishRun add to this so the Stats panel
    -- can render a "Top Zones" rollup matching the wallet totals.
    if type(DB.copperByZone) ~= "table" then
        DB.copperByZone = {}
    end
    -- v2.59.5 (Serv report): scrub city-zone entries from the per-
    -- character bucket. Mailbox-vendoring in cities had polluted the
    -- Top Zones list.
    -- v2.59.10 (bug-hunt): removed the one-shot marker gate. Downgrade
    -- -> upgrade cycles could leave the marker true while re-poisoning
    -- copperByZone via the intermediate version's un-filtered
    -- attribution. Running the scrub every EnsureDB is 10 table lookups
    -- and any-city-key removal - trivial overhead - and self-heals the
    -- edge case. DB.cityZonesScrubbed stays as a legacy tombstone.
    for zone in pairs(EC_CITY_ZONES) do
        DB.copperByZone[zone] = nil
    end
    DB.cityZonesScrubbed = true

    if type(DB.repairGear) ~= "boolean" then
        DB.repairGear = true
    end
    -- v2.9.0: opt-in guild-bank repair. Off by default so existing users
    -- keep paying out of personal funds; turning it on routes through
    -- RepairAllItems(1) when the player is in a guild AND has bank-funded
    -- repair permission AND the bank holds at least the required amount.
    if type(DB.repairUseGuildBank) ~= "boolean" then
        DB.repairUseGuildBank = false
    end

    if type(DB.enableDeletion) ~= "boolean" then
        DB.enableDeletion = true
    end
    -- v2.42.0: auto-delete Delete-List items on pickup. Account-wide (top-
    -- level) to match its gate enableDeletion; default OFF (destructive, opt-in).
    if type(DB.autoDeleteOnPickup) ~= "boolean" then
        DB.autoDeleteOnPickup = false
    end
    -- v2.44.0: auto-mark PvP gear with Resilience for deletion. Adds
    -- detected items to DB.deleteList; the existing vendor cycle (or
    -- auto-delete-on-pickup if also enabled) destroys them. Default
    -- OFF - the destination is the user's Delete List, which they
    -- might have curated for other reasons, and an unsolicited
    -- auto-mark could surprise them. Asked for by Murlocked: PvP
    -- gear on PE has sellPrice = 0 and clutters bags after farming.
    if type(DB.autoMarkResilience) ~= "boolean" then
        DB.autoMarkResilience = false
    end
    -- v2.44.4: announce auto-delete actions in chat. Covers BOTH the
    -- "Auto-deleted X" line from the auto-delete-on-pickup sweep AND
    -- the "Marked for deletion (Resilience, unsellable)" line from
    -- the resilience auto-mark sweep - same category of "EC just
    -- touched something" notification. Default ON (the player should
    -- see destructive actions); ayres asked for the off switch.
    if type(DB.announceAutoDelete) ~= "boolean" then
        DB.announceAutoDelete = true
    end
    -- v2.60.0: per-rarity filter for the auto-delete / auto-mark chat
    -- announcements. announceAutoDelete stays as the master (off silences
    -- everything); when on, each rarity's tickbox decides whether that
    -- rarity's deletion prints. Defaults all true so existing users see
    -- no behaviour change (matches the pre-v2.60.0 "all-or-nothing"
    -- toggle). Poor / Common / Uncommon / Rare / Epic keys only;
    -- higher rarities (Legendary+) are extremely rare drops that don't
    -- typically hit the auto-delete path.
    if type(DB.announceAutoDeleteQualities) ~= "table" then
        DB.announceAutoDeleteQualities = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true }
    else
        for q = 0, 4 do
            if type(DB.announceAutoDeleteQualities[q]) ~= "boolean" then
                DB.announceAutoDeleteQualities[q] = true
            end
        end
    end
    -- v2.49.2: auto-delete grey items on loot (opt-in, destructive-
    -- off-by-default). Runs from the existing BAG_UPDATE debounce
    -- alongside the auto-mark scans. See the grey auto-delete scan below.
    if type(DB.autoDeleteGreyOnLoot) ~= "boolean" then
        DB.autoDeleteGreyOnLoot = false
    end
    -- v2.49.2: warn once at PLAYER_LOGIN when a third-party auto-delete
    -- addon is running alongside EC. Opt-out; default on so the conflict
    -- is surfaced immediately without the player having to opt in first.
    if type(DB.warnConflictingAddons) ~= "boolean" then
        DB.warnConflictingAddons = true
    end
    if type(DB.summonGreedy) ~= "boolean" then
        DB.summonGreedy = true
    end
    if type(DB.summonOnlyOutOfCombat) ~= "boolean" then
        DB.summonOnlyOutOfCombat = false
    end
    -- v2.65.0 (Alckor request): auto-re-summon the Scavenger after ANY
    -- loading screen (dungeon / raid / bg / arena / hearthstone / teleporter
    -- / continent-flight) IF the pet was out immediately before the load.
    -- Blizzard's engine dismisses CRITTER-type companions across every
    -- loading screen, so the pet needs to be re-summoned by hand each
    -- time. Gating on the pre-load state (via EC_compCache.lastScavenger
    -- Out) keeps the toggle from summoning the pet when the player had
    -- deliberately dismissed it before the zone change. Default OFF
    -- (opt-in). The existing summonDelay (default 1.6 s) covers the
    -- window between load-screen-finished and Blizzard accepting the
    -- CallCompanion call.
    if type(DB.restoreScavengerAfterLoad) ~= "boolean" then
        DB.restoreScavengerAfterLoad = false
    end
    if type(DB.summonDelay) ~= "number" then
        DB.summonDelay = 1.6
    end

    if type(DB.vendorInterval) ~= "number" then
        DB.vendorInterval = 0.1
    end
    if DB.vendorInterval < 0.05 then
        DB.vendorInterval = 0.1
    end
    if type(DB.maxItemsPerRun) ~= "number" then
        DB.maxItemsPerRun = 80
    end
    if type(DB.fastMode) ~= "boolean" then
        DB.fastMode = false
    end
    -- v2.37.7: batch-vendor opt-in. When on, the worker pops multiple
    -- sells per fire instead of one, so a bag-clear finishes in a fraction
    -- of the time. Default OFF (existing setups unchanged on upgrade).
    -- Reported by a player on Discord ("2.1") that the existing fastest
    -- setting still felt slow when trying to dodge environment hazards
    -- while bag-clearing; this is the follow-up pacing pass.
    if type(DB.turboMode) ~= "boolean" then
        DB.turboMode = false
    end
    if type(DB.autoLootCycle) ~= "boolean" then
        -- v2.12.0: fresh installs default ON. The auto-loot cycle is the
        -- headline PE feature (Greedy Scavenger pet looting, Goblin
        -- Merchant auto-summon at bag-full); a brand-new user finishing
        -- the welcome popup with this still off would feel like the
        -- addon "isn't doing anything". Existing characters keep their
        -- saved value via the type-check above. The cycle gracefully
        -- no-ops on realms that lack the PE companion pets.
        DB.autoLootCycle = isFreshInstall
    end
    if type(DB.bagFullThreshold) ~= "number" then
        DB.bagFullThreshold = 2
    end
    if type(DB.autoOpenContainers) ~= "boolean" then
        DB.autoOpenContainers = false
    end
    -- v2.19.0: Project Ebonhold's roguelite system randomly applies
    -- "affix" suffixes to dropped items (e.g. `Thorbia's Gauntlets of
    -- Fortified by Pain IV` is the same itemID as the base
    -- `Thorbia's Gauntlets` but has a random suffix and an attached
    -- proc effect). A user with the base itemID on their Sell List or
    -- Delete List would inadvertently dump the affixed version, which
    -- is meaningfully different gear. This toggle gates the affix-
    -- check that skips affixed Rare/Epic instances at sell/delete
    -- decision time. Default ON because it's a safety net; users who
    -- want pre-v2.19.0 behaviour toggle it off. See
    -- EC_compCache.bagSlotHasAffix / liveTooltipHasAffix for the
    -- two-layer detection (link suffix-DBC field, then tooltip-title
    -- name-compare fallback for any custom PE mechanism).
    if type(DB.protectAffixedRareItems) ~= "boolean" then
        DB.protectAffixedRareItems = true
    end
    -- v2.23.0: Exact-rank duplicate gate on the affix protection.
    -- When ON, an affixed bag item that matches the player's already-
    -- known (affixName, rank) pair via PE's PerkService is allowed to
    -- fall through to the normal sell / DE rules. Different ranks of
    -- the same affix stay protected so the player can still collect
    -- all four. Defaults OFF so v2.22.0 upgraders see no behaviour
    -- change. Inert when Project Ebonhold isn't loaded (the per-rank
    -- known-set is empty so nothing matches).
    if type(DB.affixAllowExactDupes) ~= "boolean" then
        DB.affixAllowExactDupes = false
    end
    -- v2.44.0: affix-rank floor. When set above 0, affixed Rare /
    -- Epic items whose affix rank is BELOW this value fall through
    -- the affix protection and are eligible for normal sell / delete
    -- / process rules. Default 0 (off) so v2.43.x upgraders see no
    -- behaviour change. Asked for by Murlocked - useful on private
    -- servers like Project Ebonhold where low-tier affixes saturate
    -- the bag and the player has no use for ranks under their
    -- current ceiling. The rank is the integer pulled from the
    -- title's roman-numeral suffix by parseAffixFromTitle, so the
    -- threshold compares apples-to-apples.
    if type(DB.affixMinSellRank) ~= "number" or DB.affixMinSellRank < 0 then
        DB.affixMinSellRank = 0
    end
    -- v2.47.0: auto-mark unsellable affix dupes for deletion. When on (paired
    -- with "sell exact-rank dupes" + deletion enabled), affixed items whose
    -- affix the player already owns that are soulbound AND have no vendor value
    -- are added to the Delete List (one chat line each). Sellable dupes are
    -- left for the sell path. Default OFF (opt-in, leads to deletion). Asked
    -- for by Broyo: with all affixes collected, soulbound dupes can't be sold
    -- or traded and just clutter bags while farming.
    if type(DB.autoMarkAffixDupes) ~= "boolean" then
        DB.autoMarkAffixDupes = false
    end
    -- v2.60.0 (Serv follow-up): sub-toggle for the v2.57.2 iLvl safety
    -- net that skips auto-mark on any item at iLvl >= 200. That safety
    -- net was added to prevent a near-item-loss on brand-new high-value
    -- drops with dupe affixes (Bizzaro's report), but for a player with
    -- a mature Keep List AND autoAddEquipped / autoProtectUpgrades /
    -- autoProtectEquipmentSets on, the iLvl gate over-protects old PvP
    -- gear the player deliberately wants trashed. Default TRUE
    -- (preserves the v2.57.2 behaviour); users can untick to allow
    -- auto-mark to catch high-iLvl items. Other safety nets (Keep List,
    -- Sell List, gear-set members, currently equipped, quest items)
    -- stay unconditional.
    if type(DB.automarkProtectHighILvl) ~= "boolean" then
        DB.automarkProtectHighILvl = true
    end
    -- v2.60.0 (Serv report, Recipe: Haunted Herring / Recipe: Last Week's
    -- Mammoth): auto-mark learned profession recipes with sellPrice 0 for
    -- deletion. "Sell Known Recipes" only fires when the vendor accepts
    -- the item; a sellPrice 0 recipe stays in bags forever even when the
    -- player knows the recipe. This toggle catches those. Paired with
    -- sellKnownRecipes (that toggle must be on for this scan to run at
    -- all) so the mental model is a single "get rid of learned recipes"
    -- opt-in with two disposition paths (vendor for sellable, delete for
    -- unsellable). Default OFF (opt-in, leads to deletion).
    if type(DB.autoMarkKnownUnsellableRecipes) ~= "boolean" then
        DB.autoMarkKnownUnsellableRecipes = false
    end
    -- v2.47.0: bind-type split for "Allow selling affixes you already have".
    -- When on, only SOULBOUND owned dupes are released to the sell path; BoE
    -- owned dupes stay protected so the player can auction them. Default OFF
    -- (preserves the existing behaviour of selling all owned dupes regardless of
    -- bind). Account-wide like the other affix toggles. Asked for by Broyo: he
    -- wants soulbound dupes vendored but BoE dupes kept for the auction house.
    if type(DB.keepBoeAffixDupes) ~= "boolean" then
        DB.keepBoeAffixDupes = false
    end
    -- v2.66.0 (Valentine request): BoE-keep for the RANK FLOOR sell rule,
    -- parallel to keepBoeAffixDupes for the owned-dupe rule. When on, an
    -- affixed BoE item with rank below the 'Sell affixes below rank'
    -- setting is kept so the player can auction it. Soulbound items in
    -- the same rank band still sell as before. Default OFF (opt-in;
    -- pre-v2.66.0 behaviour is to sell all rank-below items regardless
    -- of bind, so leaving this off preserves it).
    if type(DB.keepBoeBelowRankFloor) ~= "boolean" then
        DB.keepBoeBelowRankFloor = false
    end
    -- v2.20.0: Chance-on-hit protection. PE lets players EXTRACT proc
    -- spells from weapons (the green `Chance on hit:` tooltip line)
    -- and apply them to other items, so an item with a Chance-on-hit
    -- proc is meaningfully different from the base itemID even when
    -- the user lists the base for selling. Default ON; users who
    -- don't use the extraction system can toggle it off. No quality
    -- filter (the proc text is the signal, not the rarity).
    if type(DB.protectChanceOnHitItems) ~= "boolean" then
        DB.protectChanceOnHitItems = true
    end
    -- v2.49.0: sell known chance-on-hit procs (experimental). When on,
    -- items whose chance-on-hit proc matches a PE-extracted spell in the
    -- player's spellbook fall through the chance-on-hit protection - the
    -- proc is no longer a keeper since the player has extracted it.
    -- Mirrors DB.affixAllowExactDupes for the affix side. Off by default
    -- (experimental: relies on the hand-curated EC_CHANCE_PROC_KEYWORDS
    -- seed map + on-the-fly autolearn to bridge item-side procLines to
    -- spell-side spell IDs, and coverage is item-specific).
    if type(DB.sellChanceOnHitKnown) ~= "boolean" then
        DB.sellChanceOnHitKnown = false
    end
    -- Tome protection. Tome / recipe learn-state is per-character in
    -- Project Ebonhold (only @affix@ items save account-wide via the
    -- Anvil extraction), so different alts know different tomes /
    -- recipes and may want different protection behaviour. The per-
    -- character flag matches that - one alt can vendor freely while
    -- another hoards spares for the auction house. Two independent
    -- toggles:
    --   * protectUnlearnedTomes - items that teach a spell the
    --     character does NOT yet know are HARD-vetoed by EC_IsSellable
    --     even when on the Sell List. The user must explicitly mark
    --     Allow Sell (Alt+Right-Click -> Allow Sell, ADB.allowedItems)
    --     to lift the protection. Mirrors the v2.19.0 affix protection
    --     design rather than the v2.20.1 chance-on-hit narrowing:
    --     tomes are high-value enough that "two-key" confirmation
    --     (Sell List entry + Allow Sell) is required before vendoring.
    --   * protectAllTomes - same hard-veto semantic; protects every
    --     spell-teaching item regardless of whether the character has
    --     learned it.
    if type(DB.protectUnlearnedTomes) ~= "boolean" then
        DB.protectUnlearnedTomes = true
    end
    if type(DB.protectAllTomes) ~= "boolean" then
        DB.protectAllTomes = false
    end
    -- Sell Known Recipes. Opt-in auto-sell of profession recipes the
    -- character has ALREADY learned (tooltip shows "Already known"). The
    -- toggle is account-wide like the protect* toggles above, but the
    -- learn-state is read per-character from the live tooltip at sell
    -- time (playerKnowsTomeSpell), so each alt only sells the recipes IT
    -- knows. Per-quality gate so a player can sell known white/green
    -- recipes while keeping known blue/purple ones (e.g. for the auction
    -- house). Default OFF (every auto-action is opt-in). "Protect all
    -- tomes" wins outright and disables this signal.
    if type(DB.sellKnownRecipes) ~= "boolean" then
        DB.sellKnownRecipes = false
    end
    if type(DB.sellKnownRecipeQualities) ~= "table" then
        DB.sellKnownRecipeQualities = { [1] = true, [2] = true, [3] = true, [4] = true }
    else
        for q = 1, 4 do
            if type(DB.sellKnownRecipeQualities[q]) ~= "boolean" then
                DB.sellKnownRecipeQualities[q] = true
            end
        end
    end
    -- v2.47.1: per-quality bind-type filter for Sell Known Recipes.
    -- Mirrors the quality-rule bindFilter shape from v2.10.0 so the
    -- "BoE only" / "BoP only" semantics are consistent across the
    -- two sell-rule surfaces. Default "any" everywhere keeps the
    -- v2.46.0 behaviour for existing users (additive migration).
    if type(DB.sellKnownRecipeBindFilter) ~= "table" then
        DB.sellKnownRecipeBindFilter = { [1] = "any", [2] = "any", [3] = "any", [4] = "any" }
    else
        for q = 1, 4 do
            local v = DB.sellKnownRecipeBindFilter[q]
            if v ~= "any" and v ~= "boe" and v ~= "bop" then
                DB.sellKnownRecipeBindFilter[q] = "any"
            end
        end
    end
    -- v2.22.0: Process Bags panel. Lets the player batch-cast their
    -- profession spells (Disenchant / Mill / Prospect) on eligible
    -- bag items via a secure-button macro. Soulbound DE is opt-in
    -- (default OFF) because it's irreversible; DE quality cap
    -- defaults to Epic (max permissive). Ignored items are
    -- per-character (DB, not ADB) since profession alts vary.
    if type(DB.processIncludeSoulbound) ~= "boolean" then
        DB.processIncludeSoulbound = false
    end
    if type(DB.processMaxDEQuality) ~= "number" or DB.processMaxDEQuality < 2 or DB.processMaxDEQuality > 4 then
        DB.processMaxDEQuality = 4
    end
    if type(DB.processIgnored) ~= "table" then
        DB.processIgnored = {}
    end
    -- v2.25.0: Lockpick mode in Process Bags. Adds a fourth mode (DE /
    -- Mill / Prospect / Lockpick) for rogues, listing locked containers
    -- in bags and driving Pick Lock via the existing SecureActionButton
    -- workflow. Inert on non-rogues (IsSpellKnown(1804) is false).
    -- Enabled by default since the entry point is the panel itself.
    if type(DB.lockpickEnabled) ~= "boolean" then
        DB.lockpickEnabled = true
    end
    -- v2.62.0: per-skill Process Bags toggles. A { mode = bool } table
    -- (Disenchant / Mill / Prospect / Lockpick / Convert); a missing entry
    -- means enabled, so reads use `DB.processEnabledModes[mode] ~= false`.
    -- Default empty (all skills on). Seed Lockpick once from the old
    -- DB.lockpickEnabled flag so upgraders keep their choice; lockpickEnabled
    -- is left in place (unread by new code) for downgrade safety.
    if type(DB.processEnabledModes) ~= "table" then
        DB.processEnabledModes = {}
    end
    if DB.processEnabledModes.Lockpick == nil then
        DB.processEnabledModes.Lockpick = (DB.lockpickEnabled ~= false)
    end
    -- Optional combat-exit chat hint: "N lockbox(es) available. Click
    -- Process Next to open." Default off (one extra line on every
    -- combat exit gets noisy for opted-in users with many lockboxes).
    if type(DB.lockpickNotifyOnCombatExit) ~= "boolean" then
        DB.lockpickNotifyOnCombatExit = false
    end
    -- v2.25.0: per-mode collapsed state for the Process Bags panel.
    -- Each key (Disenchant / Mill / Prospect / Lockpick) maps to true
    -- when the player has collapsed that section. Persisted so the
    -- preference survives /reload and login. Default empty (all
    -- expanded). Cursor logic in rearmProcessButton skips entries
    -- whose mode is in this set.
    if type(DB.processCollapsedModes) ~= "table" then
        DB.processCollapsedModes = {}
    end
    -- v2.16.0: Fast Loot. When on AND Blizzard's auto-loot CVar is
    -- effectively enabled, EC_HandleLootReady queues every slot in the
    -- loot window for draining, so the loot frame flashes briefly or
    -- skips entirely. Pairs with the auto-loot cycle: faster per-kill
    -- looting = bag-full threshold trips sooner = vendor cycle turns
    -- over faster. Default off so existing users keep the standard
    -- loot-window behaviour and BoP-bind safety prompts. Pattern
    -- borrowed from FasterLoot (others/FasterLoot/FasterLoot.lua).
    --
    -- v2.21.0 retrofit: drain is now queue-based with a ~110 ms
    -- throttle per slot (was: tight loop over GetNumLootItems in one
    -- frame), reducing disconnect risk on busy private servers. The
    -- toggle, schema, and BoP-bind auto-confirm are unchanged from
    -- v2.16.0; only the internal draining is refactored.
    if type(DB.fastLoot) ~= "boolean" then
        DB.fastLoot = false
    end
    if DB.merchantMode ~= "goblin" and DB.merchantMode ~= "any" and DB.merchantMode ~= "both" then
        -- v2.13.x: default flipped from "goblin" to "both" so brand-new users
        -- who haven't unlocked the Goblin Merchant pet yet still get useful
        -- auto-vendor behaviour at any normal merchant out of the box.
        -- Existing users with a saved valid value (including "goblin") keep
        -- their choice; this branch only fires when DB.merchantMode is nil
        -- or has somehow corrupted to a non-string value.
        DB.merchantMode = "both"
    end

    -- v2.9.0: companion display names are now user-editable. Defaults are the
    -- enUS strings we shipped with through v2.8.0. EnsureDB and
    -- EC_compCache.refreshNames mirror these into PET_NAME / TARGET_NAME /
    -- PET_NAME_LC locals so every existing reference picks them up without
    -- an audit of every call site.
    --
    -- v2.10.0: removed the user-facing input boxes from the Scavenger
    -- Settings panel after PE-ElvUI clickability issues made the field
    -- unreliable. The DB fields stay as a power-user override (`/run
    -- EbonClearanceDB.merchantName = ...`) but the typical case is now
    -- "fixed at default". One-time migration below resets clearly-broken
    -- values from the v2.9.0 UI session: any name that does not contain
    -- v2.13.3: dropped the v2.10.0 name-reset migration block. Once
    -- DB._v210NameReset became true on every existing user, the inner
    -- string.find guards short-circuited unconditionally; on fresh
    -- installs the EnsureDB defaults assigned just above already
    -- contain "scavenger" / "merchant", so the find checks always
    -- pass and the migration never altered anything. The cluster was
    -- write-only across all reachable code paths post-v2.10.0.
    if type(DB.scavengerName) ~= "string" or DB.scavengerName == "" then
        DB.scavengerName = "Greedy scavenger"
    end
    if type(DB.merchantName) ~= "string" or DB.merchantName == "" then
        DB.merchantName = "Goblin Merchant"
    end

    if type(DB.muteGreedy) ~= "boolean" then
        DB.muteGreedy = true
    end
    -- Hide chat + hide bubbles are now baked-in addon behaviour, not a
    -- user-toggleable setting. The DB fields are kept so existing call
    -- sites that read them (Companion.lua's chat / bubble filters) keep
    -- working without code churn, but they are unconditionally forced
    -- to true on every load - any prior `false` value from when the
    -- toggle was user-controlled gets reset. The Scavenger Settings
    -- panel's two checkboxes were removed in the same change.
    -- EC-TRAP: these look like dead flags (forced true, no UI) but are NOT
    -- dead - EbonClearance_Companion.lua's chat + bubble filters still read
    -- them. The toggles were removed; the hiding is now always-on. Do NOT
    -- delete these or the Companion read-sites.
    DB.hideGreedyChat = true
    DB.hideGreedyBubbles = true

    if type(DB.enabled) ~= "boolean" then
        DB.enabled = true
    end
    -- v2.30.x: decommission the per-character enable filter. The Enable
    -- toggle (DB.enabled) covers the per-character disable use case - and as
    -- of v2.75.0 it is genuinely per-character (a PER_CHAR_FIELDS field), so
    -- that claim now holds; the dedicated allowlist added little value and
    -- lived behind a UI panel that's been repurposed for Item Highlighting.
    -- Force the flag false on every load so existing users with the
    -- filter previously enabled don't end up locked out of the addon on
    -- characters not in their old DB.allowedChars set. DB.allowedChars
    -- itself stays in the SV (dormant, ignored) so a downgrade to a
    -- pre-v2.30.x version restores the user's list.
    -- EC-TRAP: dormant on purpose - do NOT remove this gate or the dormant
    -- DB.allowedChars field. Forcing it false guards a downgrade regression
    -- (the old per-character allowlist locking users out). See comment above.
    DB.enableOnlyListedChars = false

    if type(DB.inventoryWorthTotal) ~= "number" then
        DB.inventoryWorthTotal = 0
    end
    if type(DB.inventoryWorthCount) ~= "number" then
        DB.inventoryWorthCount = 0
    end
    if type(DB.whitelist) ~= "table" then
        DB.whitelist = {}
    end
    -- v2.10.0: parallel "source" map flagging which Blacklist (Keep) entries
    -- arrived via the auto-protect-equipped path versus a manual user add.
    -- Used by EC_AnnotateTooltip to surface "(auto-protected: equipped)" so
    -- users who expected an item to sell can see why it's being kept and
    -- follow the existing context-menu remove path to override. The
    -- blacklist check itself (IsInSet(DB.blacklist, ...)) only reads
    -- DB.blacklist; this map is purely diagnostic. Cleared in lockstep
    -- with DB.blacklist on every remove path so it can never carry a
    -- stale entry.
    if type(DB.blacklistAuto) ~= "table" then
        DB.blacklistAuto = {}
    end
    -- v2.10.0: master toggle for the auto-protect-equipped behaviour. When
    -- on, equipping an item auto-adds its ID to the per-character Blacklist
    -- (Keep) list and stamps DB.blacklistAuto. The auto-rules' blacklist
    -- veto then prevents that item from ever auto-selling. Default off so
    -- existing users see no behaviour change until they enable it from
    -- the Blacklist (Keep) panel.
    if type(DB.autoAddEquipped) ~= "boolean" then
        -- Fresh installs from v2.12.0+ default to ON so brand-new users
        -- get equipped-gear protection out of the box - matches common
        -- niche UX. Existing users (v2.10.0+ already have the field as a
        -- boolean and skip this branch; pre-v2.10.0 users hit this branch
        -- but with isFreshInstall = false) keep OFF so they don't see a
        -- silent behaviour change on upgrade.
        DB.autoAddEquipped = isFreshInstall
        if isFreshInstall and DB.autoAddEquipped then
            -- Defer the one-shot equipped-gear sync to PLAYER_LOGIN
            -- (handled at the bottom of the file) - inventory APIs
            -- aren't reliably populated at ADDON_LOADED time.
            EC_compCache.pendingFreshInstallSync = true
        end
        -- v2.12.0: arm the first-run welcome message + setup popup.
        -- Persisted via DB._needsWelcome (not session-scoped) so a
        -- /reload between ADDON_LOADED and PLAYER_LOGIN doesn't lose it.
        -- Existing characters never reach this branch because their
        -- EbonClearanceDB existed before the session and isFreshInstall
        -- is false. The flag is consumed (set to nil) by the
        -- PLAYER_LOGIN handler after the welcome fires.
        if isFreshInstall then
            -- v2.38.0: fresh installs auto-open the Quickstart panel at
            -- PLAYER_LOGIN. Renamed from the v2.12.0 `_needsWelcome` flag
            -- (which fired a 2-button popup pointing at the Main panel)
            -- to make the intent explicit: open the wizard directly.
            DB._needsQuickstartOpen = true
        end
    end
    -- v2.38.0: one-shot migration from v2.37.x. If an upgrader had the
    -- old _needsWelcome flag set (installed but never logged in), promote
    -- it to _needsQuickstartOpen so the wizard fires on their first
    -- v2.38.0 login. Clear the stale field either way.
    if DB._needsWelcome ~= nil then
        if DB._needsWelcome == true then
            DB._needsQuickstartOpen = true
        end
        DB._needsWelcome = nil
    end
    -- v2.38.0: Quickstart bookkeeping. _activeQuickstartPreset stores
    -- the most-recently-applied preset key (or nil for tailored answers)
    -- so the panel can render the "Active" tag. _previousQuickstartSnapshot
    -- captures the settings as they were just before the last Apply for
    -- one-step undo.
    if DB._activeQuickstartPreset ~= nil and type(DB._activeQuickstartPreset) ~= "string" then
        DB._activeQuickstartPreset = nil
    end
    if DB._previousQuickstartSnapshot ~= nil and type(DB._previousQuickstartSnapshot) ~= "table" then
        DB._previousQuickstartSnapshot = nil
    end
    if type(DB.autoProtectUpgrades) ~= "boolean" then
        DB.autoProtectUpgrades = false
    end
    -- v2.13.0 Equipment Manager protection. When ON, every item in any of
    -- the player's saved equipment sets (Blizzard's stock 3.3.5a Equipment
    -- Manager, NOT a third-party set addon) lands on the Keep list with
    -- origin tag "set". Solves the dual-spec / off-set problem: items
    -- assigned to your alternate gear set sit in bags between swaps and
    -- are unprotected by autoAddEquipped (which only catches currently-
    -- equipped slots). v2.57.2: default ON for new installs (Serv request -
    -- saved-set items should land on the Keep List for safety). Existing saves
    -- keep whatever the player already set; only a brand-new DB gets the ON
    -- default. Note the auto-delete gate protects set members regardless of
    -- this toggle - it only controls the visible Keep-List stamp + sell
    -- protection. EQUIPMENT_SETS_CHANGED drives live re-syncs when the user
    -- adds / modifies / deletes a set.
    if type(DB.autoProtectEquipmentSets) ~= "boolean" then
        DB.autoProtectEquipmentSets = true
    end
    if type(DB.whitelistMinQuality) ~= "number" then
        DB.whitelistMinQuality = 1
    end
    if DB.whitelistMinQuality > 3 then
        DB.whitelistMinQuality = 3
    end
    if type(DB.whitelistQualityEnabled) ~= "boolean" then
        DB.whitelistQualityEnabled = false
    end

    -- Per-rarity quality threshold rules (v2.4.0+). Replaces the old single
    -- whitelistMinQuality dropdown. Each rarity has its own enabled flag and
    -- optional max iLvl (0 = no cap). Default all off (opt-in). Existing
    -- users get a one-time migration: their old cumulative dropdown maps
    -- to per-rarity flags up to and including the chosen rarity, with no
    -- iLvl cap. The legacy keys stay for one release in case of rollback.
    if type(DB.qualityRules) ~= "table" then
        DB.qualityRules = {
            [1] = { enabled = false, maxILvl = 0 },
            [2] = { enabled = false, maxILvl = 0 },
            [3] = { enabled = false, maxILvl = 0 },
            [4] = { enabled = false, maxILvl = 0 },
        }
        if DB.whitelistQualityEnabled and type(DB.whitelistMinQuality) == "number" then
            -- Legacy migration: the old dropdown only ever offered up to
            -- quality 3. Clamp the migration source to 3 so we don't
            -- accidentally light up Epic on legacy upgraders. Existing
            -- post-v2.4 installs without the legacy keys go through the
            -- per-quality default (all off).
            local minQ = math.min(math.max(DB.whitelistMinQuality, 1), 3)
            for q = 1, minQ do
                DB.qualityRules[q].enabled = true
            end
        end
        -- v2.12.0: fresh installs default to dynamic-cap mode for whites
        -- and greens so brand-new players get useful auto-vendoring out
        -- of the box without risk - the cap follows their equipped iLvl
        -- in the same slot, so anything they're already wearing stays
        -- safe and any quest reward they haven't equipped yet would
        -- have to be a strict downgrade vs current gear to vendor.
        -- Blues and purples stay disabled - whitelist territory.
        if isFreshInstall then
            DB.qualityRules[1].enabled = true
            DB.qualityRules[1].useEquippedILvl = true
            DB.qualityRules[2].enabled = true
            DB.qualityRules[2].useEquippedILvl = true
        end
    end
    for q = 1, 4 do
        if type(DB.qualityRules[q]) ~= "table" then
            DB.qualityRules[q] = { enabled = false, maxILvl = 0 }
        end
        if type(DB.qualityRules[q].enabled) ~= "boolean" then
            DB.qualityRules[q].enabled = false
        end
        if type(DB.qualityRules[q].maxILvl) ~= "number" then
            DB.qualityRules[q].maxILvl = 0
        end
        if DB.qualityRules[q].maxILvl < 0 then
            DB.qualityRules[q].maxILvl = 0
        end
        if DB.qualityRules[q].maxILvl > 300 then
            DB.qualityRules[q].maxILvl = 300
        end
        -- v2.10.0: per-rarity bind-type filter. "any" preserves the v2.4.0+
        -- behaviour (rule applies regardless of bind type); "boe" / "bop"
        -- restrict matches to items the tooltip says bind on equip / on
        -- pickup. Items with no bind line at all (consumables, reagents)
        -- read as "any" from EC_compCache.getBindType and are protected
        -- when bindFilter is "boe" or "bop". Existing users see the "any"
        -- default; idempotent re-init matches the rest of EnsureDB.
        if type(DB.qualityRules[q].bindFilter) ~= "string" then
            DB.qualityRules[q].bindFilter = "any"
        end
        if
            DB.qualityRules[q].bindFilter ~= "any"
            and DB.qualityRules[q].bindFilter ~= "boe"
            and DB.qualityRules[q].bindFilter ~= "bop"
        then
            DB.qualityRules[q].bindFilter = "any"
        end
        -- v2.12.0: per-rarity dynamic-cap mode. When true, the maxILvl
        -- input is ignored at runtime and the cap is the equipped item's
        -- iLvl in the same slot (per-item lookup via
        -- EC_compCache.isDowngradeVsEquipped). Existing users default
        -- to false (fixed-cap mode preserved); fresh installs flip
        -- whites and greens to true via the table-init branch above.
        if type(DB.qualityRules[q].useEquippedILvl) ~= "boolean" then
            DB.qualityRules[q].useEquippedILvl = false
        end
    end
    if type(DB.minimapButtonAngle) ~= "number" then
        DB.minimapButtonAngle = 220
    end
    -- v2.44.7: minimap button visibility toggle. Default ON (existing
    -- players see no change). Off-switch is the workaround for clashes
    -- with minimap-replacement / magnifier addons (Magnify-WotLK was
    -- the trigger - Safra's report). EC stays fully functional with
    -- the button hidden: slash commands, the LDB launcher (Bazooka /
    -- Titan Panel), and key bindings all still work.
    if type(DB.minimapButton) ~= "boolean" then
        DB.minimapButton = true
    end
    -- Opt-in slot-frame border tint that highlights bag items the current
    -- rule chain would sell at the next vendor visit. Texture sits on a
    -- frame-overlay sublevel ABOVE the slot's quality-border but does not
    -- draw on the icon itself, so the icon canvas stays untouched.
    -- Off by default; users opt in via the Character Settings panel and
    -- pick their own colour through the standard colour-picker dialog.
    if type(DB.sellBorderEnabled) ~= "boolean" then
        DB.sellBorderEnabled = false
    end
    if type(DB.sellBorderColor) ~= "table" then
        DB.sellBorderColor = { r = 1.0, g = 0.82, b = 0.0, a = 0.9 }
    else
        -- Repair partially-corrupted saves so a missing component never
        -- blanks the border. Each channel falls back to the default if it
        -- isn't a number in [0, 1].
        local c = DB.sellBorderColor
        local function clamp01(v, fallback)
            if type(v) ~= "number" or v ~= v then
                return fallback
            end
            if v < 0 then
                return 0
            end
            if v > 1 then
                return 1
            end
            return v
        end
        c.r = clamp01(c.r, 1.0)
        c.g = clamp01(c.g, 0.82)
        c.b = clamp01(c.b, 0.0)
        c.a = clamp01(c.a, 0.9)
    end
    -- v2.30.x: per-category sell-border colours. Five distinct sell /
    -- delete verdicts each get their own enable toggle + colour so the
    -- user can see WHY a slot would clear at a glance. The legacy
    -- DB.sellBorderColor field stays in the SV (ignored by the new
    -- paint path) so a downgrade to v2.29.x doesn't lose the user's
    -- previous colour pick. New installs and existing-but-unmigrated
    -- saves both land on the five-category default set.
    if type(DB.sellBorderCategories) ~= "table" then
        DB.sellBorderCategories = {}
    end
    do
        local function defaultCat(r, g, b, a)
            return { enabled = true, color = { r = r, g = g, b = b, a = a } }
        end
        local CAT_DEFAULTS = {
            delete = defaultCat(1.0, 0.20, 0.20, 0.9), -- red - highest visibility
            -- v2.37.0: Keep List verdict. Soft cool white, distinct from
            -- the warm-toned sell verdicts. Reads as "pristine /
            -- protected" - the visual-reassurance use case from
            -- docs/specs/2026-05-28-keep-highlighting-design.md.
            -- Default OFF: every existing category defaults ON, but
            -- Keep is opt-in so the player picks up no NEW slot colour
            -- on the v2.37.0 upgrade unless they explicitly enable it.
            -- This matches the v2.37.0 principle of "don't change
            -- existing players' setups without their action".
            keep = { enabled = false, color = { r = 0.95, g = 0.95, b = 1.00, a = 0.9 } },
            accountSell = defaultCat(0.4, 1.0, 0.4, 0.9), -- bright green
            charSell = defaultCat(0.4, 0.7, 1.0, 0.9), -- cyan / sky blue
            junk = defaultCat(0.7, 0.7, 0.7, 0.7), -- low-alpha grey
            rule = defaultCat(1.0, 0.82, 0.0, 0.9), -- gold (matches v2.29 single-colour default)
            -- v2.37.5: random-affix items get their own at-a-glance
            -- marker so the player can spot affixed drops in bags
            -- without hovering each one. Default OFF (opt-in, like
            -- Keep List). Purple maps to the "magical / corruption"
            -- visual idiom; distinct from the warm-toned sell verdicts
            -- and the cool-toned Keep List.
            affix = { enabled = false, color = { r = 0.78, g = 0.40, b = 1.00, a = 0.9 } },
            -- v2.52.0: complementary to `affix`. Fires when the bag
            -- item carries a random affix the player does NOT own
            -- (any of description / rank / family). Gold-ish default
            -- signals "wanted / target for extraction" without
            -- clashing with the warm-toned sell family or the purple
            -- Known Affix. Default OFF (opt-in like Keep + Known Affix).
            affixneeded = { enabled = false, color = { r = 1.00, g = 0.85, b = 0.20, a = 0.9 } },
        }
        local function clamp01b(v, fallback)
            if type(v) ~= "number" or v ~= v then
                return fallback
            end
            if v < 0 then
                return 0
            end
            if v > 1 then
                return 1
            end
            return v
        end
        for cat, def in pairs(CAT_DEFAULTS) do
            local existing = DB.sellBorderCategories[cat]
            if type(existing) ~= "table" then
                DB.sellBorderCategories[cat] = {
                    enabled = def.enabled,
                    color = { r = def.color.r, g = def.color.g, b = def.color.b, a = def.color.a },
                }
            else
                if type(existing.enabled) ~= "boolean" then
                    existing.enabled = def.enabled
                end
                if type(existing.color) ~= "table" then
                    existing.color =
                        { r = def.color.r, g = def.color.g, b = def.color.b, a = def.color.a }
                else
                    existing.color.r = clamp01b(existing.color.r, def.color.r)
                    existing.color.g = clamp01b(existing.color.g, def.color.g)
                    existing.color.b = clamp01b(existing.color.b, def.color.b)
                    existing.color.a = clamp01b(existing.color.a, def.color.a)
                end
            end
        end
    end
    -- Opt-in tooltip annotation: append the numeric item ID under the EC
    -- status line on bag-item / item-link tooltips. Useful for filing bug
    -- reports and for authoring Keep / Sell / Delete entries by ID. Off
    -- by default; users opt in via the Item Highlighting panel. The line
    -- rides the same OnTooltipSetItem hook EC already installs, so there
    -- is no extra hook cost when the toggle is off.
    if type(DB.showItemIDOnTooltip) ~= "boolean" then
        DB.showItemIDOnTooltip = false
    end
    -- v2.37.0 (Borrow C): item-level text overlay on equippable gear.
    -- Master toggle + 3 sub-toggle surfaces. Bags is on by default the
    -- first time the master flips on; paperdoll + merchant default off.
    -- Once seeded, the user's sub-toggle choices persist across master
    -- toggles. Only equipLoc-whitelisted gear shows text; consumables
    -- and quest items are skipped. Spec at
    -- docs/specs/2026-05-28-keep-highlighting-design.md (Borrow C).
    if type(DB.itemLevelOverlay) ~= "table" then
        DB.itemLevelOverlay = {}
    end
    if type(DB.itemLevelOverlay.enabled) ~= "boolean" then
        DB.itemLevelOverlay.enabled = false
    end
    if type(DB.itemLevelOverlay.bags) ~= "boolean" then
        DB.itemLevelOverlay.bags = true
    end
    if type(DB.itemLevelOverlay.paperdoll) ~= "boolean" then
        DB.itemLevelOverlay.paperdoll = false
    end
    if type(DB.itemLevelOverlay.merchant) ~= "boolean" then
        DB.itemLevelOverlay.merchant = false
    end
    -- Font size for the iLvl text. Clamped to a sensible range so a
    -- corrupt SV can't render the number invisible (sub-6) or
    -- catastrophically large (>20). 12 matches the default
    -- NumberFontNormalSmall size.
    if type(DB.itemLevelOverlay.fontSize) ~= "number"
        or DB.itemLevelOverlay.fontSize < 6
        or DB.itemLevelOverlay.fontSize > 20
    then
        DB.itemLevelOverlay.fontSize = 12
    end
    if type(DB.keepBagsOpen) ~= "boolean" then
        -- v2.12.0: flipped from true to false per UX feedback - the
        -- "bags stay open after merchant closes" behaviour was felt
        -- as intrusive. Existing users with the field already set to
        -- true keep their saved value and can untick the panel toggle
        -- if they want bags closing again. New installs default off.
        DB.keepBagsOpen = false
    end
    -- v2.13.3: dropped the DB.vendorBtnShown defaulter alongside the
    -- vendor-button cluster removal. The field had no readers in any
    -- live code path post-v2.13.0 (the only consumer was
    -- EC_UpdateVendorButtonVisibility which itself was orphaned).
    if type(DB.blacklist) ~= "table" then
        DB.blacklist = {}
    end

    -- Whitelist profiles migration. First-run of the profile-aware schema:
    -- if the user already has items in the flat DB.whitelist (from pre-profile
    -- builds, or from the EbonholdStuffDB rename above), snapshot them into
    -- an "Imported" profile and auto-activate it so nothing is lost. Fresh
    -- installs get an empty Default profile as the active one. Depends on
    -- DB.whitelist having been initialised upstream -- do not reorder.
    if type(DB.whitelistProfiles) ~= "table" then
        DB.whitelistProfiles = {}
        DB.whitelistProfiles["Default"] = {}
        local hasItems = next(DB.whitelist) ~= nil
        if hasItems then
            local snapshot = {}
            for k, v in pairs(DB.whitelist) do
                snapshot[k] = v
            end
            DB.whitelistProfiles["Imported"] = snapshot
            DB.activeProfileName = "Imported"
        else
            DB.activeProfileName = "Default"
        end
    end
    if type(DB.activeProfileName) ~= "string" then
        DB.activeProfileName = "Default"
    end
    DB.whitelistProfiles["Default"] = {}
    if type(DB.blacklistProfiles) ~= "table" then
        DB.blacklistProfiles = {}
    end

    -- v2.13.3: dropped the DB._seededLists write-only guard. The seed body
    -- it once gated (item IDs 300581 / 300574, removed in the v2.0.13
    -- quality pass) hasn't existed for many releases; the flag was being
    -- written but never read. New first-install seeding, if ever needed,
    -- should use a feature-specific guard rather than reviving this one.

    -- Mirror name fields into PET_NAME / TARGET_NAME / PET_NAME_LC. Done in
    -- EnsureDB rather than in a separate helper so every caller (event hub,
    -- slash commands, settings panels) inherits the same up-to-date strings
    -- without each having to refresh manually. The companion-ID cache is
    -- wiped so the next lookup re-learns under the new names.
    if type(DB.scavengerName) == "string" and DB.scavengerName ~= "" then
        PET_NAME = DB.scavengerName
    end
    if type(DB.merchantName) == "string" and DB.merchantName ~= "" then
        TARGET_NAME = DB.merchantName
    end
    PET_NAME_LC = PET_NAME:lower()
    -- Mirror onto NS so split files (the chat filter in
    -- EbonClearance_Companion.lua, post-Stage-3) can read the live names
    -- without each owning its own upvalue rebind hook. Refreshed everywhere
    -- the file-scope names get rebound (EnsureDB here and refreshNames below).
    NS.PET_NAME = PET_NAME
    NS.TARGET_NAME = TARGET_NAME
    NS.PET_NAME_LC = PET_NAME_LC
    EC_compCache.scav = nil
    EC_compCache.merch = nil
end
-- Exposed to split files (the bug-report builder in Stage 8 calls
-- EnsureDB() to guarantee fields exist before reading them).
NS.EnsureDB = EnsureDB

-- Session stats (in-memory only; reset on /reload or by user button).
-- v2.35.x: `startedAt` is the GetTime() snapshot at session start. The
-- MainPanel's RefreshStats reads it to compute Session Gold/Hour and to
-- gate the bestGPH update on the 5-minute minimum duration. Initialised
-- at file load (so /reload starts a fresh session timer) and rewritten
-- by EC_ResetSession on the Reset Session Stats button.
local EC_session = {
    copper = 0,
    sold = 0,
    deleted = 0,
    repairs = 0,
    repairCopper = 0,
    startedAt = GetTime(),
}
NS.session = EC_session

-- Session loot ledger. Keyed by itemID -> total quantity looted this
-- session. In-memory only (clears on /reload and Reset Session). This is
-- an AGGREGATE, not an event log: storage is one small integer per
-- distinct item, so it stays bounded no matter how long the farm runs.
-- The persisted account-wide running total lives in
-- ADB.accountStats.lootedItemCounts (see EC_BumpLoot). Exposed on NS so
-- the Stats panel's loot window can read it.
local EC_lootSession = {}
NS.lootSession = EC_lootSession

local function EC_ResetSession()
    EC_session.copper = 0
    EC_session.sold = 0
    EC_session.deleted = 0
    EC_session.repairs = 0
    EC_session.repairCopper = 0
    EC_session.startedAt = GetTime()
    -- Wipe the session loot ledger in place (keep the same table object so
    -- NS.lootSession references held by the loot window stay valid).
    for k in pairs(EC_lootSession) do
        EC_lootSession[k] = nil
    end
end
NS.ResetSession = EC_ResetSession

-- Clear one scope of the loot ledger. "session" wipes the in-memory
-- session table; "account" wipes the persisted account-wide bucket. Both
-- wipe in place so existing table references stay valid.
local function EC_ClearLoot(scope)
    if scope == "account" then
        local AS = ADB and ADB.accountStats
        if AS and AS.lootedItemCounts then
            for k in pairs(AS.lootedItemCounts) do
                AS.lootedItemCounts[k] = nil
            end
        end
    elseif scope == "character" then
        if DB and DB.lootedItemCounts then
            for k in pairs(DB.lootedItemCounts) do
                DB.lootedItemCounts[k] = nil
            end
        end
    else
        for k in pairs(EC_lootSession) do
            EC_lootSession[k] = nil
        end
    end
end
NS.ClearLoot = EC_ClearLoot

-- v2.38.1: every per-character stat write mirrors into ADB.accountStats
-- so the Stats panel's Account view aggregates totals across all
-- characters. DB.* is the source of truth for the Character view; the
-- ADB.accountStats.* mirror counts forward from v2.38.1 install.
--
-- EC_BumpStat: scalar counters (totalCopper, totalItemsSold, etc.).
-- EC_BumpStatBucket: keyed sub-tables (soldItemCounts[itemID],
-- soldItemsByQuality[quality], copperByZone[zoneName], etc.).
--
-- Both helpers are defensive against missing tables - DB or ADB may not
-- exist yet when called from a corner case (e.g. an event firing during
-- ADDON_LOADED before EnsureDB runs).
local function EC_BumpStat(field, delta)
    delta = delta or 1
    if DB then
        DB[field] = (DB[field] or 0) + delta
    end
    if ADB and ADB.accountStats then
        ADB.accountStats[field] = (ADB.accountStats[field] or 0) + delta
    end
end

local function EC_BumpStatBucket(bucket, key, delta)
    delta = delta or 1
    if DB then
        DB[bucket] = DB[bucket] or {}
        DB[bucket][key] = (DB[bucket][key] or 0) + delta
    end
    if ADB and ADB.accountStats then
        ADB.accountStats[bucket] = ADB.accountStats[bucket] or {}
        ADB.accountStats[bucket][key] = (ADB.accountStats[bucket][key] or 0) + delta
    end
end

-- Session loot tracker bump. Writes the in-memory session ledger and the
-- persisted account-wide running total. Deliberately NOT routed through
-- EC_BumpStat / EC_BumpStatBucket: those also mirror into a per-character
-- DB bucket, but loot tracking is session + account only (no per-character
-- lifetime view by design). Aggregate per itemID, so it never grows into
-- an event log.
local function EC_BumpLoot(itemID, qty)
    if not itemID then
        return
    end
    qty = qty or 1
    if qty <= 0 then
        return
    end
    EC_lootSession[itemID] = (EC_lootSession[itemID] or 0) + qty
    if DB then
        DB.lootedItemCounts = DB.lootedItemCounts or {}
        DB.lootedItemCounts[itemID] = (DB.lootedItemCounts[itemID] or 0) + qty
    end
    if ADB and ADB.accountStats then
        ADB.accountStats.lootedItemCounts = ADB.accountStats.lootedItemCounts or {}
        ADB.accountStats.lootedItemCounts[itemID] = (ADB.accountStats.lootedItemCounts[itemID] or 0) + qty
    end
    -- v2.50.1: mark the Loot Log window for refresh. Its OnUpdate rebuilds
    -- on this flag (throttled) instead of unconditionally every second, so
    -- an open window costs nothing while no new loot is arriving.
    EC_compCache.lootWindowDirty = true
end

-- Loot capture. We track NET BAG INCREASES rather than parsing
-- CHAT_MSG_LOOT, because the Greedy Scavenger pet drops its haul straight
-- into your bags without firing a "you receive loot" chat line - so chat
-- parsing only ever saw what the PLAYER looted by hand. A bag-delta scan
-- catches every source uniformly: manual loot, the auto-loot cycle, AND
-- the Scavenger. Summing per itemID across all bags means moving or
-- splitting stacks nets to zero (no false count); only genuine increases
-- are recorded.
--
-- Runs from the BAG_UPDATE debounce flush (already coalesced for the
-- Scavenger's rapid multi-item bursts), so it costs one bag walk per
-- settled burst - no tooltip scans. To avoid counting non-loot inflows
-- (vendor buys / buybacks, bank or mail withdrawals, trade, auction,
-- crafting output), the scan only DIFFS when no transactional window is
-- open; while one is open it just re-baselines the snapshot so the next
-- open-world loot diffs against the right starting point.
local EC_lootBagSnapshot = {}
local EC_lootSnapshotReady = false

-- Frame NAMES (not refs) for the windows through which items legitimately
-- enter bags without being "loot". Looked up via _G at call time because
-- several are load-on-demand (GuildBankFrame, TradeFrame, AuctionFrame,
-- TradeSkillFrame, CraftFrame are nil until first opened) - and a table of
-- frame refs with nil holes would make ipairs stop at the first nil,
-- silently skipping every frame after it (the v2.46.0 bug where mailbox
-- takes were counted because GuildBankFrame was nil and short-circuited
-- the scan of MailFrame). QuestFrame / GossipFrame cover quest-reward and
-- gossip-vendor item grants.
local EC_LOOT_TXN_FRAMES = {
    "MerchantFrame",
    "BankFrame",
    "GuildBankFrame",
    "MailFrame",
    "OpenMailFrame",
    "TradeFrame",
    "AuctionFrame",
    "TradeSkillFrame",
    "CraftFrame",
    "QuestFrame",
    "GossipFrame",
}

-- True while a window is open through which items legitimately enter bags
-- without being "loot" (so we shouldn't count the delta as looted).
local function EC_LootTransactionWindowOpen()
    for i = 1, #EC_LOOT_TXN_FRAMES do
        local f = _G[EC_LOOT_TXN_FRAMES[i]]
        if f and f.IsShown and f:IsShown() then
            return true
        end
    end
    return false
end

-- Build a fresh { itemID = totalCount } snapshot across bags 0-4.
local function EC_BuildBagSnapshot()
    local snap = {}
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local id = GetContainerItemID(bag, slot)
            if id then
                local _, count = GetContainerItemInfo(bag, slot)
                snap[id] = (snap[id] or 0) + (count or 1)
            end
        end
    end
    return snap
end

-- v2.59.0: shared per-flush bag snapshot. The settled BAG_UPDATE flush used
-- to fan out into 5-9 independent full bag walks (auto-open, upgrade scan,
-- auto-delete/auto-mark scans, loot delta, grey delete) - each re-deriving
-- GetContainerItemID / GetContainerItemInfo for the same ~100 slots. The
-- flush now builds this ONCE and every scanner iterates `entries` instead
-- of walking bags; `counts` ({itemID = total}) feeds the loot-delta diff.
--
-- Validity is the FRAME it was built in (`at == GetTime()`; GetTime is
-- frame-constant on 3.3.5a): currentFlushSnapshot() returns nil on any
-- later frame, so an error mid-flush can never leave a stale snapshot
-- influencing a scanner called outside the flush. Staleness WITHIN the
-- flush (the auto-delete-on-pickup scan can synchronously destroy one
-- low-rarity item mid-chain) is handled at the consumer: every scanner
-- that runs after that point re-verifies the live slot
-- (GetContainerItemID(bag, slot) == entry.itemID) before scanning a
-- tooltip or acting destructively.
function EC_compCache.buildBagFlushSnapshot()
    local entries = {}
    local counts = {}
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local _, count, locked, quality = GetContainerItemInfo(bag, slot)
                entries[#entries + 1] = {
                    bag = bag,
                    slot = slot,
                    itemID = itemID,
                    count = count or 1,
                    locked = locked or false,
                    -- May be nil / -1 for uncached items; consumers treat
                    -- "unknown" as "check the slow path", never as "skip".
                    quality = quality,
                }
                counts[itemID] = (counts[itemID] or 0) + (count or 1)
            end
        end
    end
    return { entries = entries, counts = counts, at = GetTime() }
end

-- The flush's shared snapshot, or nil when not inside a flush frame.
function EC_compCache.currentFlushSnapshot()
    local snap = EC_compCache.flushSnapshot
    if snap and snap.at == GetTime() then
        return snap
    end
    return nil
end

-- v2.63.0: lazy acquire - return this frame's shared snapshot, building
-- and caching it on FIRST use. The flush no longer builds the snapshot
-- eagerly: in the default configuration every entries-consumer is toggled
-- off and the only flush consumer is the loot delta, which needs just the
-- flat `counts` map - so the eager build allocated ~one table per occupied
-- bag slot per burst for nobody. The first scanner that actually runs
-- builds it; every later scanner in the same frame reuses it; the flush
-- still clears the ref when it finishes.
function EC_compCache.acquireFlushSnapshot()
    local snap = EC_compCache.currentFlushSnapshot()
    if snap then
        return snap
    end
    snap = EC_compCache.buildBagFlushSnapshot()
    EC_compCache.flushSnapshot = snap
    return snap
end

-- v2.49.0: equipped snapshot for the unequip guard on EC_ScanLootDelta.
-- Reported by Serv: unequipping a worn item counts it as loot because
-- the item moves from an equipment slot to a bag slot, showing as a
-- new bag delta. Comparing this snapshot across scan runs lets us
-- detect "was equipped last scan, isn't now" and subtract that itemID
-- from the positive bag delta before crediting as loot. Standard
-- inventory slots 1-19 (INVSLOT_HEAD through INVSLOT_TABARD).
local EC_lootEquippedSnapshot = {}
-- v2.68.1: double-buffer. The scan fills the spare, diffs it against the
-- baseline, then the two tables SWAP - so this always-on BAG_UPDATE-path
-- consumer stops allocating a fresh 19-slot table (plus the `unequipped`
-- scratch below) every settled burst. Same wipe-and-reuse pattern as
-- EC_manualSell.snapshotBags. On EC_compCache, not file-scope locals:
-- the main chunk sits at Lua 5.1's 200-locals cap.
EC_compCache.lootEquippedSpare = {}
EC_compCache.lootUnequippedScratch = {}
local function EC_BuildEquippedSnapshot(into)
    wipe(into)
    if not GetInventoryItemID then
        return into
    end
    for slot = 1, 19 do
        local id = GetInventoryItemID("player", slot)
        if id then
            into[id] = (into[id] or 0) + 1
        end
    end
    return into
end

-- v2.49.1: chance-on-hit removal ring buffer. Rolling 5-second window
-- of itemIDs that vanished from bags AND had a chance-on-hit line.
-- Consumed by EC_TryAutolearnFromLearnedSpell to correlate an anvil
-- extraction (LEARNED_SPELL_IN_TAB) with the specific weapon that was
-- consumed. Session-local; never persisted.
--
-- Entry shape: { itemID, itemName, procLine, removedAt = GetTime() }.
-- Populated inside EC_ScanLootDelta's diff loop. Pruned at the start of
-- every scan pass so the window stays tight.
local EC_recentChanceProcRemovals = {}
local EC_CHANCE_PROC_WINDOW_SECONDS = 5
NS.recentChanceProcRemovals = EC_recentChanceProcRemovals
NS.chanceProcWindowSeconds = EC_CHANCE_PROC_WINDOW_SECONDS

local function EC_PruneChanceProcRemovals()
    local now = GetTime()
    local i = 1
    while i <= #EC_recentChanceProcRemovals do
        local entry = EC_recentChanceProcRemovals[i]
        if now - entry.removedAt > EC_CHANCE_PROC_WINDOW_SECONDS then
            table.remove(EC_recentChanceProcRemovals, i)
        else
            i = i + 1
        end
    end
end
NS.PruneChanceProcRemovals = EC_PruneChanceProcRemovals

-- v2.49.1: extraction catalog snapshot. Holds { [spellID] = true } for
-- every learned record at the last LEARNED_SPELL_IN_TAB event boundary.
-- Refreshed post-diff so the next event compares against the just-
-- processed state (a single Anvil session that extracts several affixes
-- fires N events, each isolating one newly-learned spellID).
local EC_extractionCatalogSnapshot = {}
NS.extractionCatalogSnapshot = EC_extractionCatalogSnapshot

local function EC_RefreshExtractionCatalogSnapshot()
    wipe(EC_extractionCatalogSnapshot)
    local catalog = EC_compCache.getExtractionCatalog()
    if type(catalog) ~= "table" then
        return
    end
    for _, rec in pairs(catalog) do
        if type(rec) == "table" and rec.id and rec.learned then
            EC_extractionCatalogSnapshot[rec.id] = true
        end
    end
end
NS.RefreshExtractionCatalogSnapshot = EC_RefreshExtractionCatalogSnapshot

-- Returns (spellID, record) if exactly one record flipped learned=false
-- -> learned=true since the snapshot. Returns nil, nil for zero (event
-- was unrelated) or multiple (batch update; can't isolate).
local function EC_FindNewlyLearnedSpell()
    local catalog = EC_compCache.getExtractionCatalog()
    if type(catalog) ~= "table" then
        return nil, nil
    end
    local foundID, foundRec, count = nil, nil, 0
    for _, rec in pairs(catalog) do
        if type(rec) == "table" and rec.id then
            if rec.learned and not EC_extractionCatalogSnapshot[rec.id] then
                foundID, foundRec = rec.id, rec
                count = count + 1
                if count > 1 then
                    return nil, nil
                end
            end
        end
    end
    if count == 1 then
        return foundID, foundRec
    end
    return nil, nil
end
NS.FindNewlyLearnedSpell = EC_FindNewlyLearnedSpell

-- v2.49.1: chance-on-hit proc autolearn core.
-- Called from the LEARNED_SPELL_IN_TAB dispatch after the catalog diff
-- has isolated a single newly-learned spellID. Also called by /ec
-- autolearnsim which pre-populates the ring buffer manually. The
-- `source` argument is "event" for the production path or "sim" for
-- the diagnostic path; only "event" refreshes the catalog snapshot.
--
-- Sanity gates (any fail -> silent skip):
--   1. spellID outside [700000, 800000) (not a PE weapon proc).
--   2. Family name required (comes from catalog record.name).
--   3. Candidate list empty after filtering NEVER_EXTRACTABLE items.
--
-- Correlation outcomes:
--   * Exactly 1 candidate -> write ADB.chanceProcConfirmedItems[itemID],
--     emit chat toast.
--   * Zero OR two-plus candidates -> write ADB.chanceProcAmbiguous
--     entry, no chat output.
local function EC_TryAutolearnFromLearnedSpell(spellID, family, source)
    if not spellID or type(spellID) ~= "number" then
        return
    end
    -- Sanity gate #1: PE weapon-proc range only. Non-weapon affixes
    -- (Iron Will 900xxx, rank-V stats 102xxx) come through the same
    -- LEARNED_SPELL_IN_TAB event but aren't chance-on-hit correlations.
    if spellID < 700000 or spellID >= 800000 then
        return
    end
    if not family or family == "" then
        family = "Unknown"
    end
    EnsureAccountDB()
    EC_PruneChanceProcRemovals()
    -- Filter NEVER_EXTRACTABLE candidates out defensively. If the hard
    -- set says PE can't extract this weapon's proc, the correlation
    -- MUST NOT trust an accidental bag-removal + spell-learn overlap.
    local candidates = {}
    for _, entry in ipairs(EC_recentChanceProcRemovals) do
        local neverSet = NS.chanceProcNeverExtractable
        if not (neverSet and neverSet[entry.itemID]) then
            candidates[#candidates + 1] = entry
        end
    end
    if #candidates == 1 then
        local candidate = candidates[1]
        ADB.chanceProcConfirmedItems[candidate.itemID] = {
            spellID = spellID,
            family = family,
            item = candidate.itemName,
            learnedAt = GetTime(),
        }
        -- EC-TRAP: this function is defined at file-scope line 1836,
        -- BEFORE the file-local `PrintNicef` at line 2258. Using the
        -- file-local here resolves at closure-creation time to nil (no
        -- upvalue exists yet) and errors at call time with "attempt to
        -- call global 'PrintNicef' (a nil value)". Reported by Serv on
        -- the /ec autolearnsim smoke test. Route through NS.PrintNicef
        -- which is exposed at line 2266 - by call time NS.PrintNicef is
        -- populated regardless of source-line ordering. Same reason the
        -- correlation-error branch below uses NS.PrintNicef too.
        NS.PrintNicef(
            L["Learned proc pairing: |cffb6ffb6%s|r extracts to |cffb6ffb6%s|r. Sell known chance-on-hit procs now covers this item."],
            candidate.itemName,
            family
        )
    else
        ADB.chanceProcAmbiguous[#ADB.chanceProcAmbiguous + 1] = {
            spellID = spellID,
            family = family,
            timestamp = GetTime(),
            source = source or "event",
            candidates = candidates,
        }
    end
    if source == "event" then
        EC_RefreshExtractionCatalogSnapshot()
    end
end
NS.TryAutolearnFromLearnedSpell = EC_TryAutolearnFromLearnedSpell

-- Diff current bags against the last snapshot and record positive deltas as
-- looted. Called from the BAG_UPDATE debounce flush. The first call after
-- login / reload only baselines (existing bag contents are not "loot").
local function EC_ScanLootDelta()
    -- Master enable gate, consistent with the other debounce-driven scans.
    if NS.IsAddonEnabledForChar and not NS.IsAddonEnabledForChar() then
        return
    end
    -- Skip entirely while an item is on the cursor: a bag reorganise picks
    -- an item up (total count drops) then drops it back (count returns).
    -- Leaving the snapshot untouched until the cursor clears means the
    -- round-trip nets to zero instead of crediting a phantom +1. Any real
    -- loot that lands while the cursor is busy is caught on the next scan.
    if CursorHasItem and CursorHasItem() then
        return
    end
    -- v2.59.0: reuse the shared flush snapshot's {itemID = count} map when
    -- inside a flush (saves a second full bag walk); standalone calls keep
    -- building their own. The shared map is never mutated after build, so
    -- retaining it as the next baseline (bottom of this function) is safe.
    local sharedSnap = EC_compCache.currentFlushSnapshot()
    local snap = sharedSnap and sharedSnap.counts or EC_BuildBagSnapshot()
    -- While a transactional window is open, or on the very first scan, just
    -- re-baseline without crediting any delta as loot.
    if not EC_lootSnapshotReady or EC_LootTransactionWindowOpen() then
        EC_lootBagSnapshot = snap
        EC_BuildEquippedSnapshot(EC_lootEquippedSnapshot)
        EC_lootSnapshotReady = true
        return
    end
    -- v2.49.0: unequip guard. Reported by Serv - unequipping a worn
    -- item moves it from an equipment slot to a bag slot, showing as
    -- a positive bag delta and getting credited as loot. Diff the
    -- equipped snapshot vs the previous run and build a per-itemID
    -- "just unequipped" count. Subtract from the bag delta before
    -- crediting. Equipping (bag -> slot) doesn't trigger a positive
    -- bag delta so no equivalent guard needed on that side.
    local equippedNow = EC_BuildEquippedSnapshot(EC_compCache.lootEquippedSpare)
    local unequipped = EC_compCache.lootUnequippedScratch
    wipe(unequipped)
    for id, prevEq in pairs(EC_lootEquippedSnapshot) do
        local nowEq = equippedNow[id] or 0
        if nowEq < prevEq then
            unequipped[id] = prevEq - nowEq
        end
    end
    -- v2.46.6: skip items the addon is about to destroy. Reported by Broyo:
    -- looted PvP-Resilience items left "item:XXXXX" ghost rows in the Loot
    -- Log because the auto-mark-resilience + auto-delete-on-pickup pair
    -- runs earlier in the same debounce burst, but the actual delete is
    -- one-per-cycle (popup serialisation invariant). Newly-marked items
    -- are still in bags when ScanLootDelta runs, then disappear on the
    -- next burst - leaving a row whose GetItemInfo hadn't yet resolved
    -- the name. EC-TRAP: must check BOTH enableDeletion AND
    -- autoDeleteOnPickup. With autoDeleteOnPickup off, items on the
    -- Delete List stay in bags until the player vendors them, so they
    -- ARE genuine loot the player handled and SHOULD count.
    local skipDeleteListed = DB and DB.enableDeletion and DB.autoDeleteOnPickup
    local deleteList = skipDeleteListed and DB.deleteList or nil
    for id, count in pairs(snap) do
        local prev = EC_lootBagSnapshot[id] or 0
        if count > prev then
            local delta = count - prev
            -- v2.49.0: subtract items just unequipped so a worn->bag
            -- transition doesn't count as loot.
            local unequipDelta = unequipped[id] or 0
            local netDelta = delta - unequipDelta
            -- NS.IsInSet rather than the file-local IsInSet because that
            -- local is declared further down in the chunk (after this
            -- function's definition point) and isn't a captured upvalue
            -- here. Same membership semantics; one extra table lookup.
            if netDelta > 0 and not (deleteList and NS.IsInSet(deleteList, id)) then
                EC_BumpLoot(id, netDelta)
            end
        end
    end
    -- v2.49.1: log chance-on-hit item REMOVALS for autolearn correlation.
    -- Walk the PREVIOUS snapshot for itemIDs whose count dropped this
    -- scan; look up the cached procLine from EC_compCache.procLineByItemID
    -- (populated during prior chanceProcLine calls before the item left);
    -- push an entry into the ring buffer. Prune stale entries first so
    -- the buffer never accumulates beyond the 5-second window.
    EC_PruneChanceProcRemovals()
    for id, prev in pairs(EC_lootBagSnapshot) do
        local now = snap[id] or 0
        if now < prev and EC_compCache.procLineByItemID and EC_compCache.procLineByItemID[id] then
            local _, link = GetItemInfo(id)
            EC_recentChanceProcRemovals[#EC_recentChanceProcRemovals + 1] = {
                itemID = id,
                itemName = link or ("item:" .. id),
                procLine = EC_compCache.procLineByItemID[id],
                removedAt = GetTime(),
            }
        end
    end
    EC_lootBagSnapshot = snap
    -- Rotate the double-buffer: the just-built table becomes the baseline,
    -- the old baseline becomes next scan's spare (wiped on fill).
    EC_compCache.lootEquippedSpare = EC_lootEquippedSnapshot
    EC_lootEquippedSnapshot = equippedNow
end
NS.ScanLootDelta = EC_ScanLootDelta

-- Keep bags open when merchant closes
local EC_keepBagsFlag = false

local function EC_OpenAllBags()
    if OpenAllBags then
        OpenAllBags()
    elseif OpenBackpack then
        OpenBackpack()
        for i = 1, 4 do
            if OpenBag then
                OpenBag(i)
            end
        end
    end
end

EC_GetPlayerName = function()
    local n = UnitName("player")
    if not n or n == "" then
        return ""
    end
    return n
end

-- v2.13.1 robustness helper for EC_IsCharacterAllowed: case-insensitive +
-- invisible-whitespace-stripped name normalisation. Catches entries added
-- with different capitalisation (user typed "zittla" but UnitName returns
-- "Zittla"), entries pasted from chat / web with embedded non-breaking
-- space (U+00A0) or zero-width joiner (U+200B), and similar look-alike
-- strings the v2.13.0 add-time trim missed. On a single PE-style private
-- server character names are unique by case, so a lowercase match cannot
-- collide with another player's name. (v2.68.1: hoisted out of the
-- function - it was a closure rebuilt on every slow-path call. Hung off
-- EC_compCache rather than a file-scope local because the main chunk sits
-- at Lua 5.1's 200-locals cap.)
function EC_compCache.stripCharName(s)
    return (s or ""):lower():gsub("[%s\194\160\226\128\139]+", "")
end

local function EC_IsCharacterAllowed()
    if not DB or not DB.enableOnlyListedChars then
        return true
    end
    if not DB.allowedChars then
        return false
    end
    local name = EC_GetPlayerName()
    -- Fast path: exact-case match (the common case for entries added via
    -- the Add Me button or typed identically).
    if DB.allowedChars[name] == true then
        return true
    end
    local target = EC_compCache.stripCharName(name)
    if target == "" then
        return false
    end
    for key, val in pairs(DB.allowedChars) do
        if val == true and type(key) == "string" and EC_compCache.stripCharName(key) == target then
            return true
        end
    end
    return false
end

EC_IsAddonEnabledForChar = function()
    if DB and DB.enabled == false then
        return false
    end
    return EC_IsCharacterAllowed()
end
-- Expose to split files. Process Bags (Stage 7+) gates its operations
-- on this; any future per-character feature can read it via NS.
NS.IsAddonEnabledForChar = EC_IsAddonEnabledForChar

-- Set-membership helper. Captures the canonical NS.IsInSet (defined in
-- EbonClearance_Core.lua); per-call cost is one local read.
local IsInSet = NS.IsInSet

-- Whitelist profile functions
local function EC_ValidateProfileName(name)
    if type(name) ~= "string" then
        return false, "Invalid name."
    end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return false, "Profile name cannot be empty."
    end
    if name:find("[:|]") then
        return false, "Profile name cannot contain : or | characters."
    end
    return true, name
end

local function EC_CountItems(tbl)
    local n = 0
    for k, v in pairs(tbl) do
        if type(k) == "number" and (v == true or v == 1) then
            n = n + 1
        end
    end
    return n
end
-- Exposed to split files (the bug-report builder in Stage 8 uses it for
-- the "Sell List Items: N" / "Account Sell List Items: N" / etc. lines).
NS.CountItems = EC_CountItems

local function EC_SaveProfile(name)
    local ok, cleaned = EC_ValidateProfileName(name)
    if not ok then
        return false, cleaned
    end
    name = cleaned
    if name == "Default" then
        return false, "The Default profile is locked to empty and cannot be overwritten."
    end
    local snapshot = {}
    for k, v in pairs(DB.whitelist) do
        snapshot[k] = v
    end
    DB.whitelistProfiles[name] = snapshot
    local blSnapshot = {}
    for k, v in pairs(DB.blacklist) do
        blSnapshot[k] = v
    end
    DB.blacklistProfiles[name] = blSnapshot
    DB.activeProfileName = name
    local wlCount = EC_CountItems(snapshot)
    local blCount = EC_CountItems(blSnapshot)
    return true, string.format('Saved profile "|cffffff00%s|r" (%d sell, %d keep).', name, wlCount, blCount)
end

local function EC_LoadProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format('Profile "%s" not found.', tostring(name))
    end
    wipe(DB.whitelist)
    -- v2.10.0: profiles persist Whitelist + Blacklist item IDs but not the
    -- "auto-added when equipped" source flag. Loading a profile is a fresh
    -- intent (the user is changing what they want protected); reset the
    -- Blacklist auto map so leftover entries from the previous profile
    -- don't bleed their tooltip annotation through.
    if type(DB.blacklistAuto) == "table" then
        wipe(DB.blacklistAuto)
    end
    for k, v in pairs(DB.whitelistProfiles[name]) do
        DB.whitelist[k] = v
    end
    wipe(DB.blacklist)
    if DB.blacklistProfiles[name] then
        for k, v in pairs(DB.blacklistProfiles[name]) do
            DB.blacklist[k] = v
        end
    end
    DB.activeProfileName = name
    local wlCount = EC_CountItems(DB.whitelist)
    local blCount = EC_CountItems(DB.blacklist)
    -- Refresh panels if they exist
    local wp = _G["EbonClearanceOptionsWhitelist"]
    if wp and wp.listUI then
        wp.listUI:Refresh()
    end
    local bp = _G["EbonClearanceOptionsBlacklist"]
    if bp and bp.listUI then
        bp.listUI:Refresh()
    end
    -- Profile load wholesale-rewrites DB.whitelist + DB.blacklist, which
    -- changes EC_IsSellable's verdict for every item previously / newly
    -- on those lists. Repaint slot-border tints so the categories
    -- (charSell / and the indirect knock-on through the rule category)
    -- track immediately. Same rule as the list-mutation refresh invariant
    -- (Test 26) and the settings-toggle refresh invariant (Test 42).
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    return true, string.format('Loaded profile "|cffffff00%s|r" (%d sell, %d keep).', name, wlCount, blCount)
end

local function EC_DeleteProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format('Profile "%s" not found.', tostring(name))
    end
    if name == "Default" then
        return false, "The Default profile cannot be deleted."
    end
    -- Count remaining profiles
    local count = 0
    for _ in pairs(DB.whitelistProfiles) do
        count = count + 1
    end
    if count <= 1 then
        return false, "Cannot delete the only remaining profile."
    end
    DB.whitelistProfiles[name] = nil
    DB.blacklistProfiles[name] = nil
    if DB.activeProfileName == name then
        DB.activeProfileName = next(DB.whitelistProfiles) or "Default"
    end
    return true, string.format('Deleted profile "|cffffff00%s|r".', name)
end

local function EC_RenameProfile(oldName, newName)
    if type(oldName) ~= "string" or not DB.whitelistProfiles[oldName] then
        return false, string.format('Profile "%s" not found.', tostring(oldName))
    end
    if oldName == "Default" then
        return false, "The Default profile cannot be renamed."
    end
    local ok, cleaned = EC_ValidateProfileName(newName)
    if not ok then
        return false, cleaned
    end
    newName = cleaned
    if newName == "Default" then
        return false, 'Cannot rename a profile to "Default".'
    end
    if newName == oldName then
        return true, "Name unchanged."
    end
    if DB.whitelistProfiles[newName] then
        return false, string.format('A profile named "%s" already exists.', newName)
    end
    DB.whitelistProfiles[newName] = DB.whitelistProfiles[oldName]
    DB.whitelistProfiles[oldName] = nil
    if DB.blacklistProfiles[oldName] then
        DB.blacklistProfiles[newName] = DB.blacklistProfiles[oldName]
        DB.blacklistProfiles[oldName] = nil
    end
    if DB.activeProfileName == oldName then
        DB.activeProfileName = newName
    end
    return true, string.format('Renamed "|cffffff00%s|r" to "|cffffff00%s|r".', oldName, newName)
end
-- Stage 8e-viii: profile-management helpers exposed on NS so the
-- ProfilesPanel (extracted into EbonClearance_ProfilesPanel.lua) can
-- reach them. Bodies remain file-scope locals in EbonClearance_Events.lua;
-- slash command handlers + the panel's button OnClicks both resolve
-- through the same NS entries.
NS.SaveProfile = EC_SaveProfile
NS.LoadProfile = EC_LoadProfile
NS.DeleteProfile = EC_DeleteProfile
NS.RenameProfile = EC_RenameProfile

-- ===========================================================================
-- v2.72.0 settings profiles (management).
-- ---------------------------------------------------------------------------
-- Unlike the list profiles above (per-character snapshots that Load COPIES
-- into the live lists), a settings profile is a LIVE body: the DB proxy
-- resolves every selling-behaviour read/write through the character's
-- active profile, so "Use" just moves the per-character pointer. Bodies
-- live at the top-level EbonClearanceDB.settingsProfiles[name] so alts
-- share a profile by pointing at the same name.
-- Defined directly on NS (no main-chunk locals - the 200-locals cap).

-- Re-fires the option panels + bag borders after the active settings
-- change under a panel's feet (same repaint set Quickstart uses).
function NS.RepaintAfterSettingsSwitch()
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    local panels = {
        "EbonClearanceOptionsMain",
        "EbonClearanceOptionsMerchant",
        "EbonClearanceOptionsBlacklistSettings",
        "EbonClearanceOptionsDeletionSettings",
        "EbonClearanceOptionsSettingsProfiles",
    }
    for _, panelName in ipairs(panels) do
        local p = _G[panelName]
        if p and p.inited and p.GetScript and p:GetScript("OnShow") then
            p:GetScript("OnShow")(p)
        end
    end
end

-- Snapshot the character's CURRENT selling settings under `name` and
-- switch to it (mirror of EC_SaveProfile's save-then-activate shape).
-- v2.75.0 (fresh-audit fix): returns the cleaned profile name if a profile with
-- that (validated) name already exists, else nil. Lets the Profiles panel raise
-- an overwrite confirmation before Save replaces an existing profile's body.
function NS.SettingsProfileExists(name)
    local ok, cleaned = EC_ValidateProfileName(name)
    if not ok then
        return nil
    end
    local profiles = EbonClearanceDB and EbonClearanceDB.settingsProfiles
    return (profiles and profiles[cleaned] ~= nil) and cleaned or nil
end

function NS.SaveSettingsProfile(name)
    local ok, cleaned = EC_ValidateProfileName(name)
    if not ok then
        return false, cleaned
    end
    local profiles = EbonClearanceDB and EbonClearanceDB.settingsProfiles
    if not profiles then
        return false, L["Settings profiles are not ready yet."]
    end
    local snap = {}
    for f in pairs(EC_compCache.settingsProfileFields) do
        -- Reads route through the proxy, so this snapshots the values
        -- the character is actually using right now.
        snap[f] = EC_DBDeepCopy(DB[f])
    end
    profiles[cleaned] = snap
    DB.activeSettingsProfile = cleaned
    return true, string.format(L['Saved settings as "|cffffff00%s|r" - this character now uses it.'], cleaned)
end

-- Point this character at an existing settings profile.
function NS.UseSettingsProfile(name)
    local profiles = EbonClearanceDB and EbonClearanceDB.settingsProfiles
    if not (profiles and name and profiles[name]) then
        return false, string.format(L['No settings profile named "|cffffff00%s|r".'], tostring(name))
    end
    if DB.activeSettingsProfile == name then
        return true, string.format(L['Already using settings profile "|cffffff00%s|r".'], name)
    end
    DB.activeSettingsProfile = name
    -- Re-run the idempotent bootstrap so a profile saved by an older
    -- version picks up nil-defaults for fields added since (the defaults
    -- write through the proxy into the newly-active profile).
    EnsureDB()
    NS.RepaintAfterSettingsSwitch()
    return true, string.format(L['This character now uses settings profile "|cffffff00%s|r".'], name)
end

function NS.DeleteSettingsProfile(name)
    if name == "Default" then
        return false, L["The Default settings profile cannot be deleted."]
    end
    local profiles = EbonClearanceDB and EbonClearanceDB.settingsProfiles
    if not (profiles and name and profiles[name]) then
        return false, string.format(L['No settings profile named "|cffffff00%s|r".'], tostring(name))
    end
    profiles[name] = nil
    -- Note whether THIS character used it before the walk below repoints
    -- every namespace (the walk includes ours).
    local repointedSelf = DB.activeSettingsProfile == name
    -- Repoint every character that used it back to Default (the proxy
    -- also falls back to Default at read time, but a live pointer to a
    -- dead profile should not persist).
    local chars = EbonClearanceDB.chars
    if chars then
        for _, charNS in pairs(chars) do
            if charNS.activeSettingsProfile == name then
                charNS.activeSettingsProfile = "Default"
            end
        end
    end
    if repointedSelf then
        -- Covers the transient pre-login namespace too (not in chars).
        DB.activeSettingsProfile = "Default"
        NS.RepaintAfterSettingsSwitch()
        return true,
            string.format(L['Deleted settings profile "|cffffff00%s|r" - this character is back on Default.'], name)
    end
    return true, string.format(L['Deleted settings profile "|cffffff00%s|r".'], name)
end

function NS.RenameSettingsProfile(oldName, newName)
    if oldName == "Default" then
        return false, L["The Default settings profile cannot be renamed."]
    end
    local ok, cleaned = EC_ValidateProfileName(newName)
    if not ok then
        return false, cleaned
    end
    local profiles = EbonClearanceDB and EbonClearanceDB.settingsProfiles
    if not (profiles and oldName and profiles[oldName]) then
        return false, string.format(L['No settings profile named "|cffffff00%s|r".'], tostring(oldName))
    end
    if profiles[cleaned] then
        return false, string.format(L['A settings profile named "|cffffff00%s|r" already exists.'], cleaned)
    end
    profiles[cleaned] = profiles[oldName]
    profiles[oldName] = nil
    local wasSelf = DB.activeSettingsProfile == oldName
    local chars = EbonClearanceDB.chars
    if chars then
        for _, charNS in pairs(chars) do
            if charNS.activeSettingsProfile == oldName then
                charNS.activeSettingsProfile = cleaned
            end
        end
    end
    if wasSelf then
        -- Covers the transient pre-login namespace too (not in chars).
        DB.activeSettingsProfile = cleaned
    end
    return true, string.format(L['Renamed settings profile "|cffffff00%s|r" to "|cffffff00%s|r".'], oldName, cleaned)
end

local function CopperToColoredText(copper)
    if not copper or copper < 0 then
        copper = 0
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100

    -- v2.58.0: comma-separate the gold amount for readability (e.g. 802,579g);
    -- silver/copper are always 0-99 so they never need it. NS.CommaNumber loads
    -- before this file, but guard defensively in case load order changes.
    local goldText = (NS.CommaNumber and NS.CommaNumber(gold)) or tostring(gold)
    local g = string.format("|cffF8D943%sg|r", goldText)
    local s = string.format("|cffC0C0C0%ds|r", silver)
    local c = string.format("|cffB87333%dc|r", cop)
    return string.format("%s %s %s", g, s, c)
end
NS.CopperToColoredText = CopperToColoredText

-- v2.66.1 iter (Serv report): gold-only variant for the Stats panel's
-- aggregate lines (Total Money Made, Total Repair Cost, Session /
-- Best Gold/Hour). Silver + copper are noise at multi-thousand-gold
-- totals. Per-item vendor prices (loot log entries, bug report line
-- items) still use the full CopperToColoredText above where the
-- silver/copper components can be meaningful.
local function CopperToGoldOnlyText(copper)
    if not copper or copper < 0 then
        copper = 0
    end
    local gold = math.floor(copper / 10000)
    local goldText = (NS.CommaNumber and NS.CommaNumber(gold)) or tostring(gold)
    return string.format("|cffF8D943%sg|r", goldText)
end
NS.CopperToGoldOnlyText = CopperToGoldOnlyText

local function PrintNice(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[EbonClearance]|r " .. msg)
end

-- Format + print convenience. Use instead of PrintNice(string.format(fmt, ...)).
local function PrintNicef(fmt, ...)
    PrintNice(string.format(fmt, ...))
end

-- Expose to split files (Stage 6+ uses NS.PrintNice / NS.PrintNicef from
-- EbonClearance_BagDisplay.lua's sellinfo trace output). EbonClearance_Events.lua's
-- own call sites keep using the file-scope upvalues.
NS.PrintNice = PrintNice
NS.PrintNicef = PrintNicef

-- Price provider seam. Returns vendor sellPrice * count. The signature
-- keeps the leading itemLink + itemID args (underscore-prefixed today)
-- so future price-source plumbing can plug in here without rewriting
-- callers.
local function EC_GetItemPrice(_itemLink, _itemID, sellPrice, count)
    return (sellPrice or 0) * (count or 1)
end

local function EC_CalcInventoryWorthCopper()
    local total = 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local _, itemCount = GetContainerItemInfo(bag, slot)
                if itemCount and itemCount > 0 then
                    local sellPrice = select(11, GetItemInfo(itemID))
                    if sellPrice and sellPrice > 0 then
                        total = total + (sellPrice * itemCount)
                    end
                end
            end
        end
    end
    return total
end

local function EC_RecordInventoryWorthSample()
    if not DB then
        return
    end
    local worth = EC_CalcInventoryWorthCopper()
    DB.inventoryWorthTotal = (DB.inventoryWorthTotal or 0) + worth
    DB.inventoryWorthCount = (DB.inventoryWorthCount or 0) + 1
end

-- EC-TRAP: this raw global override must NOT be "fixed" to hooksecurefunc.
-- v2.37.4 (audit issue #2): this is one of the few raw global overrides
-- left in the addon. hooksecurefunc is NOT a drop-in swap here because
-- the hook below intentionally SHORT-CIRCUITS the original handler when
-- an EC ID-input box is focused (the shift-click insert goes into the
-- EC field, not the chat input). hooksecurefunc always runs the original
-- first, so swapping to it would leak the link into the chat editbox.
-- The .luacheckrc allow-lists this assignment by name. Wrap-with-original
-- + early-return stays.
local EC_Original_ChatEdit_InsertLink = ChatEdit_InsertLink

local function EC_ExtractItemID(link)
    if type(link) ~= "string" then
        return nil
    end
    local id = link:match("item:(%d+)")
    if id then
        return tonumber(id)
    end
    return nil
end

ChatEdit_InsertLink = function(link)
    local box = NS.activeIDBox
    if box and box:IsShown() then
        local id = EC_ExtractItemID(link)
        if id then
            box:SetText(tostring(id))
            box:HighlightText()
            return true
        end
    end
    return EC_Original_ChatEdit_InsertLink(link)
end

-- True if the player is in a state that will silently swallow CallCompanion.
-- Catches: cast-time spells (UnitCastingInfo), channels (UnitChannelInfo),
-- and movement (GetUnitSpeed > 0). Doesn't catch the bare GCD from instant-
-- cast abilities -- 3.3.5a doesn't expose a clean GCD query -- but the
-- retry-until-confirmed loops above this layer compensate for that gap.
local function EC_IsPlayerBusy()
    if UnitCastingInfo and UnitCastingInfo("player") then
        return true
    end
    if UnitChannelInfo and UnitChannelInfo("player") then
        return true
    end
    if GetUnitSpeed and GetUnitSpeed("player") > 0 then
        return true
    end
    -- v2.11.0: GCD proxy. UNIT_SPELLCAST_SUCCEEDED stamps lastPlayerCastAt
    -- on every player cast (instant or otherwise); the GCD blocks
    -- CallCompanion for ~1.5 s afterwards. Without this, rapid instant-
    -- cast rotations slipped through the busy gate and burned the goblin
    -- summon retry budget on calls the server silently dropped.
    if (GetTime() - EC_compCache.lastPlayerCastAt) < EC_compCache.GCD_WINDOW_S then
        return true
    end
    return false
end

-- Companion lookup primitives. Match by name (case-insensitive equality), or
-- by a previously-cached creature ID. The ID path is the cheap path: a single
-- numeric compare per slot. The name path is the cold-cache fallback and the
-- post-rename recovery path. Both return (index, isSummoned, creatureID) or
-- (nil, false, nil); callers re-cache the ID on every successful hit.
-- Hung off EC_compCache rather than as module-scope locals so the helpers
-- and the cache they read share a namespace and we save two main-chunk
-- local slots (Lua 5.1 caps that at 200).
function EC_compCache.findByName(name)
    if not name or name == "" then
        return nil, false, nil
    end
    local num = GetNumCompanions("CRITTER") or 0
    local needle = string.lower(name)
    for i = 1, num do
        local cId, cName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if cName and string.lower(cName) == needle then
            return i, isSummoned, cId
        end
    end
    return nil, false, nil
end

function EC_compCache.findByID(cachedID, fallbackName)
    if cachedID then
        local num = GetNumCompanions("CRITTER") or 0
        for i = 1, num do
            local cId, _, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
            if cId == cachedID then
                return i, isSummoned, cId
            end
        end
    end
    return EC_compCache.findByName(fallbackName)
end

-- Apply DB-side companion display names to the file-scope PET_NAME /
-- TARGET_NAME / PET_NAME_LC locals and wipe the ID cache. EnsureDB does
-- the same work at the end of its body; this lightweight method is for
-- UI handlers that change a name without wanting the full DB validation
-- pass.
function EC_compCache.refreshNames()
    if not DB then
        return
    end
    if type(DB.scavengerName) == "string" and DB.scavengerName ~= "" then
        PET_NAME = DB.scavengerName
    end
    if type(DB.merchantName) == "string" and DB.merchantName ~= "" then
        TARGET_NAME = DB.merchantName
    end
    PET_NAME_LC = PET_NAME:lower()
    -- Mirror the live names onto NS for split files (see EnsureDB above
    -- for the same writes; refreshNames is the lightweight UI-handler
    -- variant and must keep the namespace in lockstep).
    NS.PET_NAME = PET_NAME
    NS.TARGET_NAME = TARGET_NAME
    NS.PET_NAME_LC = PET_NAME_LC
    EC_compCache.scav = nil
    EC_compCache.merch = nil
end

local function SummonGreedyScavenger()
    -- Don't summon while mounted (delayed calls from dismount can race with remounting)
    if IsMounted and IsMounted() then
        return
    end

    local idx, isSummoned, cId = EC_compCache.findByID(EC_compCache.scav, PET_NAME)
    if cId then
        EC_compCache.scav = cId
    end
    if not idx then
        return
    end

    if not isSummoned then
        -- v2.7.1: cast-busy gate. CallCompanion goes through the
        -- spell-cast pipeline; if the player is mid-cast / channel /
        -- moving, the server silently rejects it. Marking
        -- EC_addonDismissed=true and bailing out routes recovery
        -- through EC_TryResummonScavenger's tick path, which has
        -- the same busy gate plus retry-until-confirmed.
        if EC_IsPlayerBusy() or (DB and DB.summonOnlyOutOfCombat and InCombatLockdown()) then
            EC_compCache.addonDismissed = true
            -- v2.10.0: arm the resummon-print debounce so the eventual
            -- pet-tick retry that catches a clear cast/movement window
            -- prints once. Without this, FinishRun-initiated summons that
            -- bounce off the busy gate would silently recover. v2.11.0
            -- extends the gate with the optional combat-only setting:
            -- when DB.summonOnlyOutOfCombat is true, defer the summon
            -- until combat ends. The pet-tick retry path picks it up
            -- the moment InCombatLockdown clears.
            EC_compCache.pendingAnnounce = true
            return
        end
        -- Dismiss any active critter first, then summon Scavenger
        if DismissCompanion then
            DismissCompanion("CRITTER")
        end
        CallCompanion("CRITTER", idx)
        -- v2.9.0: anchor the user-dismiss-vs-leash classification window.
        -- A subsequent out -> not-out transition within EC_compCache.USER_WINDOW_S
        -- of this timestamp is treated as "the user clicked the portrait off".
        EC_compCache.lastSummonAt = GetTime()
        -- v2.13.8: print the recovery acknowledgement line on this happy
        -- path too, not just in EC_TryResummonScavenger's busy-gate-
        -- recovery branch. Historically the line was firing only when
        -- the cycle was slow enough that SummonGreedyScavenger got
        -- busy-gated and the pet-tick had to take over via
        -- EC_TryResummonScavenger; on the happy path
        -- (CallCompanion succeeds directly) the pet-tick observed the
        -- false->true transition and silently cleared pendingAnnounce
        -- without printing. The user expected the line as a close-out
        -- on every bag-full cycle. Print it here so the close-out fires
        -- regardless of which path actually completed the summon.
        if EC_compCache.pendingAnnounce then
            PrintNice(L["|cff00ff00Greedy Scavenger resummoned.|r"])
            EC_compCache.pendingAnnounce = false
        end
        -- v2.11.0: do NOT clear EC_addonDismissed here. A combat
        -- keypress that lands in the same client tick as CallCompanion
        -- can take the cast slot and silently reject the summon; if
        -- we'd already cleared EC_addonDismissed the pet-tick retry
        -- path (the only thing that would catch the rejection) is
        -- disarmed and the Scavenger stays gone for the rest of the
        -- session. The pet-tick at the EC_PetCheckTick transition
        -- handler is the canonical "summon confirmed" signal and
        -- clears EC_addonDismissed after observing scavengerOut=true.
        -- Same model v2.6.1 applied to EC_TryResummonScavenger. The
        -- pendingAnnounce flag IS cleared above because the print
        -- has already fired; the retry path's silent-on-retry
        -- behaviour is preserved by the cleared flag.
    else
        -- Already out on entry: CallCompanion is a no-op, safe to clear
        -- both flags here (no rejection window to worry about).
        EC_compCache.addonDismissed = false
        EC_compCache.pendingAnnounce = false
    end
    -- Sync the stuck-detection gate immediately so the OnUpdate
    -- accumulator starts counting from this summon, not from the
    -- next 5 s tick observation.
    EC_compCache.lastScavengerOut = true
    EC_scavMovementAccum = 0
    if DB and DB.autoLootCycle then
        EC_compCache.lootCycleState = STATE.LOOTING
    end
end

local function DismissGreedyScavenger()
    EC_compCache.addonDismissed = true
    EC_compCache.lastScavengerOut = false
    EC_scavMovementAccum = 0
    if DismissCompanion then
        DismissCompanion("CRITTER")
    else
        local num = GetNumCompanions("CRITTER")
        if not num or num <= 0 then
            return
        end
        for i = 1, num do
            local _, creatureName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
            if creatureName == PET_NAME and isSummoned then
                CallCompanion("CRITTER", i)
                return
            end
        end
    end
end

-- The spellID branch is the localisation escape hatch. If a future Ebonhold
-- realm ships with a non-enUS name for the Goblin Merchant companion, the
-- name match fails but the spellID match still finds it. See TARGET_NAME
-- note at the top of the file.
local GOBLIN_MERCHANT_SPELL_ID = 600126

-- The "CRITTER" companion type in the 3.3.5a API covers both cosmetic vanity
-- pets AND functional companions like the Goblin Merchant on Project Ebonhold
-- -- they share one companion slot. That's why summoning the Merchant
-- dismisses the Scavenger and vice versa: they can't coexist.
--
-- Lookup is ID-first (cheap, survives a future rename / localisation), with a
-- name fallback that also matches on spellID 600126 so the very first lookup
-- on a fresh client still resolves the merchant before any cache exists.
local function FindGoblinMerchantIndex()
    if EC_compCache.merch then
        local num = GetNumCompanions("CRITTER") or 0
        for i = 1, num do
            local cId, _, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
            if cId == EC_compCache.merch then
                return i, isSummoned
            end
        end
    end
    local num = GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cId, creatureName, spellID, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if creatureName == TARGET_NAME or spellID == GOBLIN_MERCHANT_SPELL_ID then
            EC_compCache.merch = cId
            return i, isSummoned
        end
    end
    return nil
end

-- Locate the Greedy Scavenger in the player's companion list. Returns
-- (index, isSummoned). index is nil if the pet isn't in the list at all
-- (e.g. user hasn't learned it). ID-first lookup keeps the rename / L10n
-- escape hatch consistent with the merchant path.
local function EC_FindGreedyScavenger()
    local idx, isSummoned, cId = EC_compCache.findByID(EC_compCache.scav, PET_NAME)
    if cId then
        EC_compCache.scav = cId
    end
    if not idx then
        return nil, false
    end
    return idx, isSummoned
end

-- SummonGoblinMerchant / DismissGoblinMerchant helpers were removed: the
-- auto-loot-cycle pet management now drives the merchant companion via
-- EC_TickGoblinSummon and friends; nothing else called these wrappers.

-- Returns a coloured string describing the user's current binding for the
-- "Target Goblin Merchant" action, or a prompt if none is bound. Used in
-- the summon-confirmation chat line so users can discover the keybind.
local function EC_FormatTargetMerchantBinding()
    if not GetBindingKey then
        return "your bound key"
    end
    local key = GetBindingKey("CLICK EbonClearanceTargetMerchantButton:LeftButton")
    if key and key ~= "" then
        return "|cffffff00" .. key .. "|r"
    end
    return "|cffaaaaaaa key|r (bind one in ESC > Key Bindings > EbonClearance)"
end

local EC_wasMounted = false
local EC_mountDismissTime = 0
-- STATE, EC_lootCycleState, EC_addonDismissed are forward-declared at the
-- top of the file so functions compiled earlier capture them as upvalues.

local EC_delayFrame = CreateFrame("Frame")
local EC_timers = {}

local function EC_Delay(seconds, func)
    if type(func) ~= "function" then
        return
    end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        func()
        return
    end
    EC_timers[#EC_timers + 1] = { t = seconds, f = func }
end

EC_delayFrame:SetScript("OnUpdate", function(self, elapsed)
    if #EC_timers == 0 then
        return
    end
    for i = #EC_timers, 1, -1 do
        local item = EC_timers[i]
        item.t = item.t - elapsed
        if item.t <= 0 then
            table.remove(EC_timers, i)
            local ok, err = pcall(item.f)
            if not ok and geterrorhandler then
                geterrorhandler()(err)
            end
        end
    end
end)
-- Expose EC_Delay to split files via NS. Used by post-Stage-7
-- EbonClearance_Process.lua and any future split file that needs to
-- schedule a delayed callback. The forward-declared `EC_delayFrame`
-- and `EC_timers` stay local to this file; only the scheduling helper
-- is part of the namespace surface.
NS.Delay = EC_Delay

local function EC_SummonGreedyWithDelay()
    if not DB or not DB.summonGreedy then
        return
    end
    EC_Delay((DB and DB.summonDelay) or 1.6, SummonGreedyScavenger)
end

local function EC_GetFreeBagSlots()
    local free = 0
    for bag = 0, 4 do
        local numFree = GetContainerNumFreeSlots(bag)
        if numFree then
            free = free + numFree
        end
    end
    return free
end
NS.GetFreeBagSlots = EC_GetFreeBagSlots

-- Stuck-detection threshold (seconds of player movement) above which we
-- assume the Scavenger has been left behind and dismiss-then-re-summon at
-- the player's current position. The CRITTER companion tries to follow but
-- stops on rough terrain or once the player outruns it.
--
-- We use a movement-time accumulator instead of measuring distance because
-- UnitPosition("pet") doesn't return data for CRITTER-type companions on
-- 3.3.5a (the unit ID "pet" refers to combat pets only). GetUnitSpeed works
-- universally and is what we accumulate against in the OnUpdate.
--
-- v2.6.1 raised this from 20 s to 180 s (in two steps: 20->60 then 60->180
-- after in-game testing). 20 s of cumulative movement happens inside
-- ~60-90 s of normal questing, so the original value triggered a dismiss-
-- and-resummon roughly every minute or two even when the pet wasn't
-- actually stuck. 60 s was less twitchy but still fired during ordinary
-- kill-loot-move play. 180 s leaves the pet alone through normal questing
-- cadence -- mob fight, loot, move on, repeat -- and only intervenes when
-- the player has been moving for a sustained period that's almost
-- certainly outpaced the leash.
local EC_STUCK_MOVEMENT_THRESHOLD = 180

-- Fast Mode: when enabled, pin the per-item vendor interval to the 0.05 s
-- floor and double the per-run cap. Opt-in via DB.fastMode.
local function EC_EffectiveVendorInterval()
    if DB and DB.fastMode then
        return 0.05
    end
    local i = (DB and DB.vendorInterval) or 0.1
    if i < 0.05 then
        i = 0.05
    end
    return i
end

local function EC_EffectiveMaxItemsPerRun()
    if DB and DB.fastMode then
        return 160
    end
    return (DB and DB.maxItemsPerRun) or 80
end

-- v2.37.7: Turbo Mode pops multiple items off the queue per worker fire
-- so a bag clear finishes in a fraction of the time. Stacks with Fast
-- Mode: with both on the effective rate is 4 / 0.05 = 80 items/sec.
-- Standalone Turbo with default 0.1 s interval = 40 items/sec. The
-- batch size is deliberately small (4) so the per-frame UseContainerItem
-- burst stays well inside what server-side rate limiting will accept;
-- the per-run cap still applies. Surfaced in the Merchant panel; the
-- effective items/sec readout under the slider reflects the current
-- combination.
local TURBO_BATCH_SIZE = 4

local function EC_EffectiveBatchSize()
    if DB and DB.turboMode then
        return TURBO_BATCH_SIZE
    end
    return 1
end

-- Pet-cycle timer/flag locals. MUST be declared before EC_HandleBagFullForCycle:
-- that function (BAG_UPDATE handler) writes EC_summonGoblinPending /
-- EC_summonGoblinTimer, and Lua resolves writes to whatever is in scope at the
-- function's parse site. If these aren't locals yet, the writes leak to _G and
-- the OnUpdate consumer at the bottom (which captures them as locals) never
-- sees them - the cycle hangs in WAITING_MERCHANT forever. This is the same
-- trap v2.0.13 fixed for STATE / running / EC_lootCycleState; see CLAUDE.md
-- convention #4.
-- Pet-check tick interval. Below this, the OnUpdate body returns early.
-- 5 s is the cadence used for state reconciliation, stuck detection, and
-- re-summon - low enough to react to a despawn within a reasonable window
-- but high enough to avoid scanning companion state every frame.
local EC_PET_CHECK_INTERVAL = 5
local EC_petCheckElapsed = 0
local EC_summonGoblinPending = false
local EC_summonGoblinTimer = 0
local EC_targetGoblinPending = false
local EC_targetGoblinTimer = 0
-- Counter of CallCompanion attempts in the current bag-full cycle. When the
-- 2 s verify (EC_TickGoblinTarget) sees the Goblin not summoned, we re-arm
-- the dismiss-then-summon path with a short delay so EC_TickGoblinSummon's
-- cast-busy gate gets another chance to fire during a clear window. v2.6.2
-- raised the cap from a single retry (boolean) to EC_GOBLIN_MAX_RETRIES
-- attempts: under heavy combat the bare GCD from instant-cast rotations
-- can swallow several attempts in a row before one lands cleanly.
-- Reset to 0 at every fresh bag-full cycle in EC_HandleBagFullForCycle.
local EC_goblinRetryCount = 0
local EC_GOBLIN_MAX_RETRIES = 3
local EC_merchantReminderPending = false
local EC_merchantReminderTimer = 0
-- Auto-open container in-flight flag. Same forward-declaration discipline as
-- the timers above: EC_HandleAutoOpenContainers writes this, and we don't want
-- the write to leak into _G if the function is parsed before the local exists.
local EC_autoOpenInFlight = false

-- v2.21.0: Fast Loot queue state hung off EC_compCache to stay under
-- Lua 5.1's 200-locals-per-main-chunk cap (CLAUDE.md discipline). The
-- queue replaces v2.16.0's tight-loop drain with a slot-index queue
-- that drains via OnUpdate throttle, reducing per-frame LootSlot
-- pressure to mitigate disconnect risk on busy 3.3.5a private
-- servers. EC_compCache.lootQueue is initialised here so the OnUpdate
-- driver (built lazily in EC_HandleLootReady) can reach it via
-- EC_compCache. Resets naturally on /reload and on every LOOT_READY
-- (re-population wipes + refills).
EC_compCache.lootQueue = {
    slots = {},
    isProcessing = false,
    lastLootAt = 0,
    delay = 0.11, -- 110 ms; matches the reference implementation's default
    frame = nil, -- built lazily in EC_HandleLootReady on first call
}

-- Auto-loot cycle: react to bag-full as soon as the game tells us a bag
-- changed. Same body as the old 5-second poll; called from BAG_UPDATE so the
-- Goblin Merchant is summoned within a tick of the threshold being crossed.
-- Idempotent: the STATE.LOOTING guard prevents double-summon under burst events.
local function EC_HandleBagFullForCycle()
    if not DB or not DB.autoLootCycle then
        return
    end
    if EC_compCache.lootCycleState ~= STATE.LOOTING then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if EC_compCache.vendorRunning then
        return
    end
    if IsMounted() then
        return
    end
    local free = EC_GetFreeBagSlots()
    if free > (DB.bagFullThreshold or 2) then
        -- v2.11.0: clear the hysteresis stamp the moment we rise back
        -- above the threshold. A subsequent dip will start a fresh
        -- confirm window from the new GetTime().
        EC_compCache.bagFullSince = nil
        return
    end
    -- v2.11.0 hysteresis: require the threshold to be continuously
    -- crossed for BAG_FULL_CONFIRM_S before tearing down the looting
    -- pet and summoning the merchant. Suppresses spurious cycles on
    -- transient bag fluctuations. The scheduled re-check guarantees
    -- the cycle still fires if no further BAG_UPDATE arrives during
    -- the confirm window (e.g. one big loot leaves the player idle).
    if not EC_compCache.bagFullSince then
        EC_compCache.bagFullSince = GetTime()
        EC_Delay(EC_compCache.BAG_FULL_CONFIRM_S + 0.05, EC_HandleBagFullForCycle)
        return
    end
    if (GetTime() - EC_compCache.bagFullSince) < EC_compCache.BAG_FULL_CONFIRM_S then
        return
    end
    EC_compCache.bagFullSince = nil
    EC_compCache.lootCycleState = STATE.WAITING_MERCHANT
    PrintNicef(L["|cffffff00%d free bag slots left. Summoning Goblin Merchant...|r"], free)
    if DismissCompanion then
        DismissCompanion("CRITTER")
    end
    -- v2.9.0: signal that this dismiss is addon-driven so the dismiss-vs-leash
    -- classifier in EC_PetCheckTick doesn't mis-classify the bag-full
    -- transition as a manual portrait click and trip a 30 s grace that
    -- would block the post-merchant Scavenger restore (especially during
    -- heavy combat, where the busy-gated retry path needs every tick).
    -- The flag stays true through WAITING_MERCHANT/SELLING (pet-tick is
    -- gated on those states so it can't act on it) and is cleared by
    -- SummonGreedyScavenger when FinishRun brings the Scavenger back.
    EC_compCache.addonDismissed = true
    -- v2.10.0: arm the resummon-print debounce. If FinishRun's
    -- SummonGreedyScavenger hits the busy-gate the recovery falls through
    -- to EC_TryResummonScavenger; that path's chat line should fire once
    -- so the user gets a matching close-out for the bag-full / Goblin-
    -- summoned messages.
    EC_compCache.pendingAnnounce = true
    EC_summonGoblinPending = true
    EC_summonGoblinTimer = 1.5
    EC_goblinRetryCount = 0
end

-- v2.44.5: watchdog for the bag-full → goblin-summon swap. nohsi + Shandrax
-- both reported the swap getting stuck: bags full, scavenger still out,
-- bagFullSince stamped 20+ seconds ago, lootCycleState still LOOTING. One
-- of EC_HandleBagFullForCycle's five early-return gates is silently
-- blocking the transition. Leading suspect: EC_compCache.vendorRunning
-- stuck at true (the only gate not currently surfaced in /ec bugreport).
--
-- The watchdog detects this stuck signature and force-resets the cycle to
-- IDLE; the next pet tick re-syncs scavenger-out and EC_HandleBagFullForCycle
-- re-arms. 7.5 s is 5x the BAG_FULL_CONFIRM_S hysteresis window - well past
-- any normal-case retry. Hooked from EC_petCheckFrame's OnUpdate so the
-- 5 s pet-tick cadence applies.
local EC_BAG_FULL_STUCK_S = 7.5
local function EC_BagFullWatchdog()
    if not DB or not DB.autoLootCycle then
        return
    end
    if EC_compCache.lootCycleState ~= STATE.LOOTING then
        return
    end
    if not EC_compCache.bagFullSince or EC_compCache.bagFullSince <= 0 then
        return
    end
    if (GetTime() - EC_compCache.bagFullSince) < EC_BAG_FULL_STUCK_S then
        return
    end
    local free = EC_GetFreeBagSlots()
    if free > (DB.bagFullThreshold or 2) then
        -- Bags freed up but the hysteresis stamp wasn't cleared - clean it.
        EC_compCache.bagFullSince = nil
        return
    end
    if IsMounted() then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        return
    end
    -- Stuck signature confirmed. Force-reset the cycle. EC_compCache.vendorRunning
    -- gets cleared because it's the leading suspect for the original block; if
    -- it was legitimately true, the worker's next OnUpdate at line ~4861
    -- already handles vendorRunning=false + merchant-closed by exiting cleanly.
    PrintNice(L["|cffffb84dScavenger swap cycle appeared stuck; resetting. If this recurs, please send /ec bugreport.|r"])
    EC_compCache.vendorRunning = false
    EC_compCache.bagFullSince = nil
    EC_compCache.lootCycleState = STATE.IDLE
end

-- v2.44.5: expose the four state values that pinpoint which gate of
-- EC_HandleBagFullForCycle is blocking. Consumed by /ec bugreport so the
-- next stuck-swap report names the culprit instead of leaving us to guess.
NS.GetSwapDiagnostics = function()
    return {
        vendorRunning = EC_compCache.vendorRunning,
        summonGoblinPending = EC_summonGoblinPending,
        summonGoblinTimer = EC_summonGoblinTimer,
        goblinRetryCount = EC_goblinRetryCount,
    }
end

-- ===========================================================================
-- Auto-open lootable containers
-- ---------------------------------------------------------------------------
-- Hidden tooltip used to scan bag items for the "Right Click to Open" line,
-- bind type detection, PE affix + chance-on-hit detection, and Process Bags
-- mode detection. Anchored offscreen via SetOwner(UIParent, "ANCHOR_NONE")
-- so it never flashes on the user's screen during scans.
--
-- Lives in this file (not EbonClearance_Protection.lua) because callers
-- exist in both Protection and non-protection code (auto-open driver,
-- Process Bags helpers, bug-report builder). Exposed on the namespace so
-- EbonClearance_Protection.lua can dereference it lazily at call time
-- (Protection loads BEFORE this file, so an upvalue capture at Protection's
-- load would store nil).
local EC_scanTooltip = CreateFrame("GameTooltip", "EbonClearanceScanTooltip", UIParent, "GameTooltipTemplate")
EC_scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
NS.scanTooltip = EC_scanTooltip

-- v2.68.1: memoised access to the scan tooltip's line FontStrings. Every
-- offscreen tooltip scanner used to rebuild the global name per line per
-- scan (`_G["EbonClearanceScanTooltipTextLeft" .. i]`) - a throwaway
-- string + _G hash lookup per iteration, ~1,000+ allocations per scanner
-- pass on a cold-cache bag walk. Once a line FontString exists it is a
-- stable session-long reference (fixed frame name), so cache it forever.
--
-- MUST stay lazy-fill, NOT an eager loop at load: GameTooltipTemplate only
-- pre-creates the first line FontStrings; the client materialises higher
-- indices on demand as tooltips grow. An eager array would freeze nil for
-- every not-yet-rendered line and silently truncate all scans. The
-- metatable fires only on a miss; after the rawset, reads are plain hash
-- hits. A nil return (line not created yet) keeps today's `break`
-- semantics in every scan loop. Consumers in Protection/Process/BugReport
-- read EC_compCache.scanLines at CALL time (those files load before this
-- one - the Test 41 load-order trap).
EC_compCache.scanLines = setmetatable({}, {
    __index = function(t, i)
        local fs = _G["EbonClearanceScanTooltipTextLeft" .. i]
        if fs then
            rawset(t, i, fs)
        end
        return fs
    end,
})

-- v2.38.3: SetOwner-before-SetBagItem invariant. WoW's GameTooltip
-- silently drops ownership when something calls :Hide() on it - and
-- anyone iterating UIParent's children (host bag UI replacements, host
-- UI replacements, profiling addons) can trigger that hide unexpectedly.
-- Once ownership is gone, every SetBagItem on this frame populates zero
-- lines and the tooltip-scan-based predicates (processTooltipHasLine,
-- itemHasChanceOnHit, processIsSoulbound, canPickLock, sell-info /
-- delete-list scans, etc.) silently return false. The cache then
-- poisons with "none" until /reload.
--
-- All scan-tooltip call sites in the addon must go through this helper.
-- It re-establishes ownership defensively so SetBagItem always works.
-- Cost: two extra C calls per scan; negligible vs. the silent-failure
-- mode this prevents.
function EC_compCache.scanBagItem(bag, slot)
    EC_scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    EC_scanTooltip:ClearLines()
    EC_scanTooltip:SetBagItem(bag, slot)
    return EC_scanTooltip
end

-- v2.75.0: the same scan, by itemID instead of bag slot. SetHyperlink
-- works for ANY item, including ones the player has never owned, which is
-- what lets the pair cross-check read a candidate weapon's proc line
-- without holding it (the Anvil needs the physical item; this does not).
--
-- Subject to the same SetOwner-before-Set invariant as scanBagItem above -
-- see that comment. Returns nil when the client has no data for the ID
-- yet; SetHyperlink itself is what asks the server for it, so a caller
-- that gets nil should try again on a later pass rather than conclude the
-- item has no proc.
function EC_compCache.scanItemID(itemID)
    if not itemID then
        return nil
    end
    EC_scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    EC_scanTooltip:ClearLines()
    EC_scanTooltip:SetHyperlink("item:" .. itemID)
    if not GetItemInfo(itemID) then
        return nil
    end
    return EC_scanTooltip
end

-- Forward declaration so the debounce frame's OnUpdate closure below
-- can resolve the name. Without this, Lua's lexical scoping resolves
-- the reference to the (nil) global at closure-creation time and the
-- auto-open driver never fires from the debounce path. v2.24.0 perf
-- regression discovered post-v2.25.0 when locked boxes that the user
-- opened via Process Bags weren't being auto-opened by the debounce.
-- Function body still lives at its original spot below.
local EC_HandleAutoOpenContainers

-- v2.24.0: BAG_UPDATE coalescing frame. The Greedy Scavenger looting
-- 5 items in <100 ms fires 5 BAG_UPDATE events; running the full
-- deferred-work chain (auto-open containers, upgrade scan, Process
-- Bags rearm, panel refresh) per-event caused 1.5 s freezes in
-- v2.22.0+v2.23.0. This frame's OnUpdate watches a "burst settled"
-- accumulator and fires the work once after the configured idle
-- window. EC_HandleBagFullForCycle stays synchronous (kept inline in
-- the OnEvent branch) so the bag-full cycle's responsiveness is
-- unchanged. State on EC_compCache to stay under Lua 5.1's 200-
-- locals cap.
EC_compCache.bagUpdatePending = false
EC_compCache.bagUpdateAccum = 0
EC_compCache.BAG_UPDATE_DEBOUNCE_S = 0.12 -- 120 ms idle window
EC_compCache.bagUpdateFrame = CreateFrame("Frame")
EC_compCache.bagUpdateFrame:Hide()

-- ------------------------------------------------------------------
-- Frame-spike diagnostic (session-only). A cheap always-on watchdog
-- watches per-frame time; when a single frame runs long enough to be a
-- visible hitch, it records how many milliseconds EC spent in each of
-- its heavy phases that frame (bag-update flush, vendor cycle, tooltip
-- annotation) and flags the worst offender. Surfaced by /ec spike.
--
-- Phase counters are cumulative wall-clock ms from debugprofilestop - a
-- high-res timer that, unlike CPU profiling, is always available on
-- 3.3.5a with no CVar. The watchdog only reads deltas, so the counters
-- climbing over a session is harmless. Everything is in-memory and
-- bounded; it clears on /reload and is never persisted.
--
-- Perf: the watchdog does a few subtractions per frame and allocates a
-- table only on an actual spike, so it adds no measurable per-frame cost
-- and touches none of the BAG_UPDATE coalescing state.
local EC_prof = debugprofilestop
local EC_SPIKE_THRESHOLD_S = 0.05 -- ~50 ms frame: a visible micro-stutter
local EC_SPIKE_CEILING_S = 2.0 -- ignore loading-screen / alt-tab mega-frames
local EC_SPIKE_LOG_MAX = 20
local EC_SPIKE_EPSILON_MS = 0.1 -- "EC did real work this frame" floor
local EC_spikeLog = {}
-- Cumulative ms per phase. Exposed on EC_compCache so the tooltip module
-- (a separate file) can add to the same counters.
local EC_spikePhase = { bagupdate = 0, vendor = 0, tooltip = 0 }
EC_compCache.spikePhase = EC_spikePhase
EC_compCache.spikeProf = EC_prof
NS.recentSpikeLog = EC_spikeLog
NS.recentSpikeLogMax = EC_SPIKE_LOG_MAX
-- v2.76.0: the worst-N frames of the session, sorted descending by ms,
-- so one big hitch is not evicted by twenty later small ones (the
-- recent ring above is a severity-blind FIFO). Entries are SHARED with
-- NS.recentSpikeLog - never mutate an entry after insert.
NS.worstSpikeLog = {}
NS.worstSpikeLogMax = 10

local EC_spikeFrame = CreateFrame("Frame")
local EC_spikePrevBag, EC_spikePrevVendor, EC_spikePrevTip = 0, 0, 0
EC_spikeFrame:SetScript("OnUpdate", function(_, elapsed)
    local p = EC_spikePhase
    local dBag = p.bagupdate - EC_spikePrevBag
    local dVendor = p.vendor - EC_spikePrevVendor
    local dTip = p.tooltip - EC_spikePrevTip
    EC_spikePrevBag = p.bagupdate
    EC_spikePrevVendor = p.vendor
    EC_spikePrevTip = p.tooltip
    if elapsed < EC_SPIKE_THRESHOLD_S or elapsed > EC_SPIKE_CEILING_S then
        return
    end
    -- Which EC phase ate the most time during this hitch?
    local dom, domMs = nil, EC_SPIKE_EPSILON_MS
    if dBag > domMs then
        dom, domMs = "Bag update", dBag
    end
    if dVendor > domMs then
        dom, domMs = "Vendor cycle", dVendor
    end
    if dTip > domMs then
        -- Last phase checked: nothing reads domMs after this, so only the
        -- winning label needs updating (leaving domMs here would be a dead
        -- write - luacheck flags it).
        dom = "Tooltip scan"
    end
    -- Only record hitches EC actually contributed to. An empty /ec spike
    -- after a stutter storm is itself the answer: EC wasn't busy then.
    if not dom then
        return
    end
    -- v2.76.0: ecMs (EC's total work this frame) is captured at insert
    -- because the entry is shared between the recent and worst rings and
    -- immutable after this point; the display derives the percentage.
    -- The phase deltas are cumulative-counter differences, so ecMs >= 0.
    local entry = {
        ms = elapsed * 1000,
        dominant = dom,
        bagMs = dBag,
        vendorMs = dVendor,
        tipMs = dTip,
        ecMs = dBag + dVendor + dTip,
        fps = (GetFramerate and GetFramerate()) or 0,
        loggedAt = date("%H:%M:%S"),
    }
    table.insert(EC_spikeLog, 1, entry)
    if #EC_spikeLog > EC_SPIKE_LOG_MAX then
        table.remove(EC_spikeLog)
    end
    -- Worst ring: sorted insert (descending by ms) with a replace-min
    -- early-out, then trim the tail. Eviction is by SEVERITY, never
    -- FIFO - the whole point is that a 400 ms hitch survives twenty
    -- later 51 ms ones. Strict < in the scan keeps equal-ms entries in
    -- arrival order (oldest of equals ranks first).
    local worst = NS.worstSpikeLog
    if #worst < NS.worstSpikeLogMax or entry.ms > worst[#worst].ms then
        local pos = #worst + 1
        while pos > 1 and worst[pos - 1].ms < entry.ms do
            pos = pos - 1
        end
        table.insert(worst, pos, entry)
        if #worst > NS.worstSpikeLogMax then
            table.remove(worst)
        end
    end
end)

-- Copyable list of frame hitches: the worst of the session (biggest
-- first) then the most recent (newest first), each line showing EC's
-- share of the frame so a pasted report proves whose stutter it was.
-- Backs the /ec spike command. Session-only - both rings clear on /reload.
function NS.ShowFrameSpikes()
    local body
    if #EC_spikeLog == 0 then
        body = L["No frame hitches blamed on EbonClearance this session. Either there were none, or EbonClearance wasn't doing heavy work during any slow frame. Clears on /reload."]
    else
        -- v2.76.0: the share is derived here from the stored ecMs; the
        -- clamp guards the two-clock case (debugprofilestop vs elapsed)
        -- ever pushing it past 100.
        local function fmtLine(e)
            local ms = tonumber(e.ms) or 0
            local ecMs = tonumber(e.ecMs) or 0
            local pct = ms > 0 and math.min(100, ecMs / ms * 100) or 0
            -- When EC's total rounds to 0 ms, naming an EC phase as "busiest"
            -- reads as blame on a frame the share just exonerated. Same
            -- wording as the Help answer: the stutter came from something
            -- else. Raw English like the phase labels (line content is
            -- unlocalized diagnostic text; only the headers are L-wrapped).
            local busiest = ecMs < 0.5 and "something else" or tostring(e.dominant or "?")
            return string.format(
                "[%s] %.0f ms hitch - busiest: %s - EC %.0f of %.0f ms (%.0f%%)  |cff888888(bag %.0f / vendor %.0f / tooltip %.0f ms, %.0f FPS)|r",
                tostring(e.loggedAt or "?"),
                ms,
                busiest,
                ecMs,
                ms,
                pct,
                tonumber(e.bagMs) or 0,
                tonumber(e.vendorMs) or 0,
                tonumber(e.tipMs) or 0,
                tonumber(e.fps) or 0
            )
        end
        local lines = {}
        lines[#lines + 1] = L["Worst hitches this session (biggest first):"]
        for i = 1, #NS.worstSpikeLog do
            lines[#lines + 1] = fmtLine(NS.worstSpikeLog[i])
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = L["Most recent hitches (newest first):"]
        for i = 1, #EC_spikeLog do
            lines[#lines + 1] = fmtLine(EC_spikeLog[i])
        end
        body = table.concat(lines, "\n")
    end
    if NS.ShowCopyFrame then
        NS.ShowCopyFrame(L["EbonClearance: Frame Hitches"], body)
    else
        PrintNice(body)
    end
end

EC_compCache.bagUpdateFrame:SetScript("OnUpdate", function(self, elapsed)
    EC_compCache.bagUpdateAccum = EC_compCache.bagUpdateAccum + elapsed
    if EC_compCache.bagUpdateAccum < EC_compCache.BAG_UPDATE_DEBOUNCE_S then
        return
    end
    self:Hide()
    EC_compCache.bagUpdatePending = false
    -- Frame-spike timing: the whole settled-burst flush (loot-delta scan
    -- included) is the "bag update" phase.
    local _spikeT0 = EC_prof and EC_prof()
    EC_StampEvent("bagUpdate")
    -- v2.75.0 (fresh-audit fix): resolve any deferred external-delete candidate
    -- now that the bag burst has settled and the cursor is likely clear.
    if EC_compCache.confirmPendingExternalDelete then
        EC_compCache.confirmPendingExternalDelete()
    end
    -- v2.63.0: the shared bag snapshot is now acquired LAZILY - the first
    -- scanner below that actually runs builds it via
    -- EC_compCache.acquireFlushSnapshot() and later scanners in this same
    -- frame reuse it. With every entries-consumer toggled off (the default
    -- config) no snapshot is built at all; the loot delta falls back to
    -- its cheap flat {itemID = count} walk.
    -- Burst settled. Fire the deferred work once.
    if EC_HandleAutoOpenContainers then
        EC_HandleAutoOpenContainers()
    end
    if EC_compCache.checkBagsForUpgrades then
        EC_compCache.checkBagsForUpgrades()
    end
    if EC_compCache.rearmProcessButton then
        EC_compCache.rearmProcessButton()
    end
    -- v2.26.0: cheap dirty-check rebuild of the known-affix /
    -- known-proc description map. Skips the rebuild when the player's
    -- learned-record count hasn't changed since the last fire. Picks
    -- up post-extraction state from the Enchanted Anvil without
    -- needing a /reload.
    if EC_compCache.refreshExtractionIfDirty then
        EC_compCache.refreshExtractionIfDirty()
    end
    local pbp = _G["EbonClearanceOptionsProcessBags"]
    if pbp and pbp:IsShown() and EC_compCache.refreshProcessPanel then
        EC_compCache.refreshProcessPanel()
    end
    -- v2.30.x: repaint slot-border tints after the bag burst settles.
    -- The host bag UI's per-slot Update hook fires immediately during
    -- a move - while the slot is still locked - and NS.IsSellable
    -- bails on locked items, so the category resolver returns nil and
    -- the tint hides. For list-based categories (delete / account
    -- sell / character sell) the host's follow-up UpdateBorder often
    -- catches things up via the search-fade path, but rule-category
    -- items (which depend entirely on qualityPass via NS.IsSellable)
    -- don't always get a second pass. Refreshing here after the
    -- 120 ms idle ensures the locked state has cleared by the time
    -- the final paint runs. The refresh iterates only tracked buttons
    -- (weak-keyed registry) so the cost is one category lookup per
    -- visible bag slot - bounded by the user's open bag count.
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    -- v2.42.0: auto-delete-on-pickup runs from the debounce (NOT the raw
    -- BAG_UPDATE branch) so the coalescing invariant holds.
    if EC_compCache.runAutoDeleteOnPickup then
        EC_compCache.runAutoDeleteOnPickup()
    end
    -- v2.44.0: auto-mark Resilience PvP gear for deletion. Runs from
    -- the same debounce so the BAG_UPDATE coalescing applies. The
    -- helper itself routes through EC_IsAddonEnabledForChar so the
    -- master Enable toggle vetoes consistently with every other
    -- destructive path.
    if EC_compCache.runAutoMarkResilience then
        EC_compCache.runAutoMarkResilience()
    end
    -- v2.47.0: auto-mark unsellable affix dupes (soulbound, owned affix, no
    -- vendor value) for deletion. Same debounce + master-gate discipline as
    -- the resilience auto-mark above.
    if EC_compCache.runAutoMarkAffixDupes then
        EC_compCache.runAutoMarkAffixDupes()
    end
    -- v2.60.0: auto-mark learned recipes with sellPrice 0 (Sell Known Recipes
    -- can't move them; they'd sit in bags forever). Same debounce + master-
    -- gate discipline as the two auto-marks above.
    if EC_compCache.runAutoMarkKnownUnsellableRecipes then
        EC_compCache.runAutoMarkKnownUnsellableRecipes()
    end
    -- Loot tracker bag-delta scan. Runs last in the flush: auto-delete-on-
    -- pickup confirms its delete asynchronously (via the delete popup on a
    -- later tick), so a just-looted Delete-List item is still in bags when
    -- this scan runs and gets counted before the async delete removes it on
    -- a subsequent burst.
    if EC_ScanLootDelta then
        EC_ScanLootDelta()
    end
    -- v2.49.2: grey auto-delete. Runs LAST in the flush - after the
    -- loot-delta scan above - so a just-looted grey is counted as loot
    -- before the (synchronous, no-popup) delete removes it. Opt-in via
    -- DB.autoDeleteGreyOnLoot; self-gates on the master Enable +
    -- enableDeletion. One delete per burst; the delete re-fires the
    -- debounce for the next.
    if EC_compCache.runAutoDeleteGrey then
        EC_compCache.runAutoDeleteGrey()
    end
    -- Drop the shared snapshot reference; the frame stamp already stops
    -- cross-frame reuse, this just lets the tables GC promptly.
    EC_compCache.flushSnapshot = nil
    if _spikeT0 then
        EC_spikePhase.bagupdate = EC_spikePhase.bagupdate + (EC_prof() - _spikeT0)
    end
end)

-- True iff the slotted item shows ITEM_OPENABLE in its tooltip and is not
-- locked. ITEM_OPENABLE is the standard Blizzard locale string ("<Right
-- Click to Open>" in enUS) used by every container, gift bag, and
-- treasure pouch in 3.3.5a. LOCKED is the same string that gets shown on
-- junkboxes / lockpickable containers; we exclude those because the user
-- needs a key or lockpicking skill to open them.
local function EC_IsOpenable(bag, slot)
    -- v2.59.0: per-itemID cache. "never" skips the slot with zero API calls.
    -- v2.59.3 fix (Serv report, lockbox auto-open loop): we NO LONGER cache
    -- "openable" per-itemID. Bug scenario: rogue Pick Lock unlocks lockbox
    -- A of itemID X, cache stamps X="openable", another still-locked
    -- lockbox of itemID X in bags then skipped the tooltip re-scan and
    -- relied on GetContainerItemInfo's `locked` field. That field is
    -- unreliable for never-picked lockboxes in 3.3.5a - it flips true only
    -- when the item is mid-cast / mid-swap, not "requires unlock". So the
    -- still-locked box passed the openable check, UseContainerItem fired,
    -- server refused, 0.4s retry loop spammed the "item is locked" chat
    -- error. The tooltip LOCKED line is the only reliable per-instance
    -- signal, so always do the tooltip scan.
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return false
    end
    local cached = EC_compCache.openableCache[itemID]
    if cached == "never" then
        return false
    end
    local _, itemCount, locked = GetContainerItemInfo(bag, slot)
    if not itemCount or itemCount <= 0 or locked then
        return false
    end
    -- v2.38.3: SetOwner-before-SetBagItem via the shared helper.
    EC_compCache.scanBagItem(bag, slot)
    -- Cap iterations: tooltips can technically grow long; 30 lines is more
    -- than any container we care about will produce.
    local sawAnyLine = false
    for i = 1, 30 do
        local line = EC_compCache.scanLines[i]
        if not line then
            break
        end
        local txt = line:GetText()
        if txt and txt ~= "" then
            sawAnyLine = true
        end
        if txt == LOCKED then
            -- Do NOT return before checking for ITEM_OPENABLE elsewhere in
            -- the tooltip - keep scanning. But: a "Locked" line is
            -- definitive: this instance is not openable right now. Never
            -- cache "openable" for the itemID either (a different instance
            -- of same itemID could be locked - the cache would poison the
            -- next call). Just return false.
            return false
        end
        if txt == ITEM_OPENABLE then
            -- Deliberately NOT caching "openable" per the v2.59.3 fix
            -- comment above.
            return true
        end
    end
    -- Only negative-cache when the tooltip actually rendered: an uncached
    -- item (client data still warming up) produces an empty tooltip, and
    -- caching "never" from that would permanently skip a real container.
    if sawAnyLine then
        EC_compCache.openableCache[itemID] = "never"
    end
    return false
end

-- Auto-open driver. Walks bags, opens the first openable item, and recurses
-- via EC_Delay if more remain. EC_autoOpenInFlight coalesces BAG_UPDATE
-- bursts so we never stack `UseContainerItem` calls within the inter-item
-- delay. Reassigns the forward-declared `EC_HandleAutoOpenContainers` local
-- (declared above near the v2.24.0 BAG_UPDATE debounce frame, so the
-- frame's OnUpdate closure can capture this name). Body lives in this file
-- because it references file-scope locals EC_IsOpenable + EC_autoOpenInFlight.
function EC_HandleAutoOpenContainers()
    if not DB or not DB.autoOpenContainers then
        return
    end
    if EC_compCache.vendorRunning then
        return
    end
    if InCombatLockdown() then
        -- Session-scoped one-shot deferral announce. The earlier per-combat
        -- variant re-fired the message on every combat instance that
        -- happened to have a BAG_UPDATE-during-combat with openable items
        -- in bag; rogues leveling with lockboxes in bag (continuous kill-
        -- mob-combat cycle) saw the line spam. The flag is now NEVER
        -- cleared at PLAYER_REGEN_ENABLED, so a user sees the deferral
        -- notice at most once per /reload. The driver still resumes
        -- post-combat through PLAYER_REGEN_ENABLED's EC_HandleAutoOpenContainers
        -- call; the message is just discoverability, not load-bearing.
        --
        -- Short-circuit openable scan: walk bags but bail on the first
        -- openable, so the worst case (no openables in bag) is bounded by
        -- a single bag walk per /reload. Without this gate, the announce
        -- would fire on every combat-during-BAG_UPDATE event regardless of
        -- whether anything is actually deferred.
        if not EC_compCache.combatDeferredAnnounced then
            EC_compCache.combatDeferredAnnounced = true
            local hasOpenable = false
            local snap = EC_compCache.acquireFlushSnapshot()
            for i = 1, #snap.entries do
                local e = snap.entries[i]
                if EC_IsOpenable(e.bag, e.slot) then
                    hasOpenable = true
                    break
                end
            end
            if hasOpenable then
                PrintNice(L["Containers deferred until out of combat."])
            end
        end
        return
    end
    if EC_autoOpenInFlight then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    -- v2.59.0: iterate the shared flush snapshot (or a fresh one when
    -- called outside the flush, e.g. from PLAYER_REGEN_ENABLED or the
    -- post-open EC_Delay retry). EC_IsOpenable re-reads the live slot, so
    -- a snapshot entry that has moved just resolves to "not openable".
    local snap = EC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        local e = snap.entries[i]
        if EC_IsOpenable(e.bag, e.slot) then
            EC_autoOpenInFlight = true
            UseContainerItem(e.bag, e.slot)
            -- 0.4 s gives the prior open's cast room to finish before we
            -- trigger the next one. Tunable; lower would feel snappier
            -- but risks interrupting the previous use.
            EC_Delay(0.4, function()
                EC_autoOpenInFlight = false
                EC_HandleAutoOpenContainers()
            end)
            return
        end
    end
end

-- v2.10.0: bind-type detection for the per-rarity bindFilter rule. Returns
-- "boe", "bop", or "any". v2.69.0: the walk itself lives in the shared
-- EC_compCache.scanItemMarkers (EbonClearance_Protection.lua), which fills
-- bind + chance-on-hit + Resilience from ONE tooltip pass, matches the
-- CLIENT-LOCALIZED bind globals (ITEM_BIND_ON_PICKUP / ITEM_SOULBOUND /
-- ITEM_BIND_ON_EQUIP - the old enUS literals silently degraded every
-- bind filter to "any" on French/German clients), and never caches from
-- a tooltip that hasn't rendered. Results stay on EC_compCache.bindCache
-- because bind type is immutable for a given itemID.
--
-- Items with no bind line at all (consumables, reagents, trade goods,
-- quest items) return "any" - they aren't subject to BoE-only or BoP-only
-- filters, which is the user-intended behaviour: "Sell BoE only" should
-- not sweep up reagents.
function EC_compCache.getBindType(bag, slot)
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return "any"
    end
    local cached = EC_compCache.bindCache[itemID]
    if cached then
        return cached
    end
    if EC_compCache.scanItemMarkers then
        EC_compCache.scanItemMarkers(bag, slot, itemID)
    end
    return EC_compCache.bindCache[itemID] or "any"
end

-- v2.10.0: bind-type detection that reads a live tooltip's lines instead
-- of scanning a freshly-built EC_scanTooltip via SetBagItem. Used by
-- EC_AnnotateTooltip so the bind-filter rule can colour-code an item the
-- user is hovering when we don't have a (bag, slot) pair (the annotation
-- entry point is itemLink, not a container slot). Reads the cache first
-- so a previously-scanned bag item never re-scans; otherwise walks the
-- live tooltip's TextLeft lines for the same client-localized bind
-- globals the bag-scan path matches (v2.69.0; was enUS literals). Stamps
-- the cache on a successful result so a subsequent EC_IsSellable call on
-- the same itemID stays cheap.
function EC_compCache.getBindTypeFromTooltip(tooltip, itemID)
    if itemID and EC_compCache.bindCache[itemID] then
        return EC_compCache.bindCache[itemID]
    end
    if not tooltip or not tooltip.NumLines or not tooltip.GetName then
        return "any"
    end
    local tname = tooltip:GetName()
    if not tname then
        return "any"
    end
    local n = tooltip:NumLines() or 0
    local result = "any"
    local bopLine = ITEM_BIND_ON_PICKUP or "Binds when picked up"
    local sbLine = ITEM_SOULBOUND or "Soulbound"
    local boeLine = ITEM_BIND_ON_EQUIP or "Binds when equipped"
    -- Start at line 2: line 1 is the item name; bind line is always one of
    -- the early header lines (line 2 or 3 in 3.3.5a item tooltips).
    for i = 2, n do
        local fs = _G[tname .. "TextLeft" .. i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if txt then
                if txt == bopLine or txt == sbLine then
                    result = "bop"
                    break
                elseif txt == boeLine then
                    result = "boe"
                    break
                end
            end
        end
    end
    if itemID then
        EC_compCache.bindCache[itemID] = result
    end
    return result
end

-- The PE random-affix detection cluster (linkHasAffix, romanToInt,
-- parseAffixFromTitle, scanTooltipForAffixDesc, normaliseAffixDesc,
-- bagSlotAffixData and siblings), the chance-on-hit detection cluster
-- (lineLooksLikeChanceProc, itemHasChanceOnHit, liveTooltipHasChanceOnHit),
-- the PE engraving-spell catalog integration (refreshKnownAffixes,
-- refreshExtractionIfDirty, playerHasAffixDescription,
-- knownAffixDescriptions / procIdToDescription tables), and the
-- v2.26.0 Anvil bridge (findLearnedAffixForItem, itemAffixLookupCache)
-- all live in EbonClearance_Protection.lua (Stage 4 of the file split,
-- see docs/CODE_REVIEW.md item 4). Every helper is attached to
-- EC_compCache, so call sites elsewhere in this file already resolve
-- through the shared upvalue and need no changes.

-- v2.21.0: pre-flight bag-space check used by the Fast Loot queue
-- before each LootSlot call. Returns true if the item can fit (free
-- slot in a compatible bag, OR room in an existing stack). False
-- means bags are too full - the queue defers, and the loot window
-- stays open for the player to deal with manually. Money and items
-- with no link (currency drops) always return true since they don't
-- consume bag space.
function EC_compCache.canLootItem(link)
    if not link then
        return true
    end
    local itemFamily = GetItemFamily and GetItemFamily(link) or 0
    local totalFree = 0
    for i = 0, NUM_BAG_SLOTS do
        local free, bagFamily = GetContainerNumFreeSlots(i)
        bagFamily = bagFamily or 0
        -- bagFamily 0 = generic bag, accepts anything. Non-zero =
        -- specialty bag (quiver, soul shard pouch, etc.) - only
        -- accepts items whose family bit matches.
        if free and (bagFamily == 0 or (itemFamily and bit.band(itemFamily, bagFamily) > 0)) then
            totalFree = totalFree + free
        end
    end
    if totalFree > 0 then
        return true
    end
    -- Bags full but check if the item can stack into an existing
    -- partial stack of the same item.
    local have = GetItemCount and GetItemCount(link) or 0
    if have > 0 then
        local _, _, _, _, _, _, _, stackSize = GetItemInfo(link)
        if stackSize and stackSize > 1 then
            local remainder = have % stackSize
            if remainder > 0 then
                return true
            end
        end
    end
    return false
end

-- The Process Bags engine (Disenchant / Mill / Prospect / Lockpick
-- eligibility predicates + spell IDs + buildProcessSummary bag walk)
-- lives in EbonClearance_Process.lua after Stage 7 of the file split.
-- The Process Bags PANEL (rearmProcessButton, refreshProcessPanel,
-- updateProcessSelection, skipProcessTarget + the SecureActionButton
-- UI) stays in this file for Stage 8 because it pulls in a dense web
-- of UI-building helpers. See docs/CODE_REVIEW.md item 4.


-- v2.21.0: Fast Loot driver. Replaces v2.16.0's tight-loop drain
-- (which fired N LootSlot calls in one frame and risked anti-flood
-- disconnect on busy 3.3.5a private servers) with a queue + OnUpdate
-- throttle: on LOOT_READY, the slot indices are pushed into
-- EC_lootQueue.slots and the OnUpdate driver below drains one slot
-- every EC_LOOT_QUEUE_DELAY seconds. Each pop re-validates the slot
-- and pre-checks bag space before calling LootSlot. The 0.3 s
-- LOOT_READY debounce from v2.16.0 is gone - re-populating the queue
-- on a fresh LOOT_READY is idempotent (wipe + refill).
--
-- The "auto-loot is effectively on right now?" check is unchanged
-- from v2.16.0: autoLootDefault is the CVar setting, AUTOLOOTTOGGLE
-- is the modifier key (typically Shift) that inverts auto-loot for
-- one interaction. When the CVar's value matches whether the
-- modifier is held, auto-loot is OFF for this loot (user is
-- explicitly opting OUT - or didn't opt IN); when they differ,
-- auto-loot is ON. Skip when off so the user keeps the standard
-- loot window for selective looting.
--
-- BoP-bind auto-confirm (also v2.16.0) is unchanged: the
-- hooksecurefunc on LootSlot fires whether the call comes from the
-- old tight loop or the new queue. Fast Loot users still don't see
-- the bind popup.
local function EC_HandleLootReady()
    if not DB or not DB.fastLoot then
        return
    end
    if GetCVarBool("autoLootDefault") == IsModifiedClick("AUTOLOOTTOGGLE") then
        return
    end
    local n = GetNumLootItems()
    if n == 0 then
        return
    end
    local q = EC_compCache.lootQueue
    -- Lazy-build the OnUpdate driver frame on first LOOT_READY. Lives
    -- for the rest of the session; cheap when DB.fastLoot is off
    -- because the OnUpdate body bails on isProcessing == false.
    if not q.frame then
        q.frame = CreateFrame("Frame")
        q.frame:SetScript("OnUpdate", function(self)
            local qs = EC_compCache.lootQueue
            if not qs.isProcessing then
                return
            end
            if (GetTime() - qs.lastLootAt) < qs.delay then
                return
            end
            if #qs.slots == 0 then
                qs.isProcessing = false
                return
            end
            local slotIdx = qs.slots[1]
            table.remove(qs.slots, 1)
            -- Per-slot revalidation: server-side loot state can
            -- desync from the snapshot at LOOT_READY (a slot can
            -- become invalid before we reach it).
            local _, _, _, _, locked = GetLootSlotInfo(slotIdx)
            if locked then
                -- BoP / roll item: leave for player. The existing
                -- BoP-bind auto-confirm hook only fires AFTER a
                -- successful LootSlot, so skipping here leaves the
                -- loot window open for manual handling.
                return
            end
            -- Bag-space pre-check: avoids ERR_INV_FULL spam in the
            -- chat frame when bags are full.
            local link = GetLootSlotLink(slotIdx)
            if link and not EC_compCache.canLootItem(link) then
                return
            end
            qs.lastLootAt = GetTime()
            LootSlot(slotIdx)
        end)
    end
    wipe(q.slots)
    for i = n, 1, -1 do
        q.slots[#q.slots + 1] = i
    end
    q.isProcessing = true
    q.lastLootAt = 0
end

-- ===========================================================================

-- ===========================================================================
-- Right-click bag-item context menu (Alt+Right-Click)
-- ---------------------------------------------------------------------------
-- Adds an EbonClearance popup to bag items: Whitelist (Character/Account),
-- Blacklist, Deletion List, Sell Now. Triggered by Alt+Right-Click so it
-- doesn't override the default right-click-to-use behaviour. We replace
-- (rather than hooksecurefunc) ContainerFrameItemButton_OnClick because we
-- need to *suppress* the default action on our modifier combo, not just
-- append.
--
-- Implementation: a hand-built popup frame with regular Buttons. We avoid
-- UIDropDownMenu in "MENU" mode because 3.3.5a's implementation has a known
-- issue where the click handlers on menu items silently no-op when parented
-- to a custom frame.

local EC_CTX_PANEL_FOR = {
    whitelist = "EbonClearanceOptionsWhitelist",
    accountWhitelist = "EbonClearanceOptionsAccountWhitelist",
    blacklist = "EbonClearanceOptionsBlacklist",
    deleteList = "EbonClearanceOptionsDeletion",
}

-- v2.37.4: refresh every list panel that's been opened at least once. Used
-- by the tooltip backfill in EC_AnnotateTooltip when it stamps a NEW
-- side-meta entry (affixedListedItems / chanceOnHitListedItems) so the
-- (affix-gated) / (Hit-proc) tag appears immediately on the visible row
-- instead of needing the user to close and reopen the panel. Walking the
-- four list-panel name globals is cheap (each Refresh is O(visible rows)).
local function EC_RefreshAllListPanels()
    for _, panelName in pairs(EC_CTX_PANEL_FOR) do
        local panel = _G[panelName]
        if panel and panel.listUI and panel.listUI.Refresh then
            panel.listUI:Refresh()
        end
    end
end
NS.RefreshAllListPanels = EC_RefreshAllListPanels

-- v2.10.0: optional `quiet` flag suppresses the success / dedupe / conflict
-- chat lines and returns true on a successful add, false on dedupe, conflict
-- or unresolved list. Used by the auto-protect-equipped one-shot sync (which
-- prints a single summary line for the whole 19-slot walk) and by the
-- PLAYER_EQUIPMENT_CHANGED reactive handler (which prints one targeted line
-- per add). The default-mode call sites are unchanged - they pass nil for
-- quiet and ignore the return value.
-- v2.51.0: session-scoped silent-refusal log. EC_AddItemToList's cross-list
-- conflict guard refuses adds silently when called with quiet=true (the
-- auto-protect sync path uses quiet=true, so a Keep-List add for an
-- equipped item that's already on Delete List returns false with zero
-- diagnostic trail). That silent-refusal path was the root cause of the
-- Stickybackpack shirt-loss bug (v2.50.2). Ring buffer preserves the
-- last N refusals so /ec bugreport surfaces them. Session-local, wiped
-- on /reload. Ring shifts oldest out on overflow.
local EC_SILENT_REFUSAL_LOG_MAX = 15
local EC_silentRefusalLog = {}
EC_LogSilentRefusal = function(itemID, targetList, conflictList, caller)
    if not itemID then
        return
    end
    if #EC_silentRefusalLog >= EC_SILENT_REFUSAL_LOG_MAX then
        table.remove(EC_silentRefusalLog, 1)
    end
    local _, link = GetItemInfo(itemID)
    EC_silentRefusalLog[#EC_silentRefusalLog + 1] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        targetList = targetList or "?",
        conflictList = conflictList or "?",
        caller = caller or "?",
        loggedAt = date("%H:%M:%S"),
    }
end
NS.silentRefusalLog = EC_silentRefusalLog
NS.silentRefusalLogMax = EC_SILENT_REFUSAL_LOG_MAX

local function EC_AddItemToList(setName, itemID, label, quiet)
    if not itemID then
        return false
    end
    local t = EC_GetListTable(setName)
    if not t then
        if not quiet then
            PrintNicef(L["|cffff4444Could not resolve list: %s|r"], tostring(setName))
        end
        return false
    end
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    if t[itemID] then
        if not quiet then
            PrintNicef(L["|cffaaaaaa%s already on %s.|r"], itemName, label)
        end
        return false
    end
    -- Cross-intent conflict guard. Refuse adds that would create a multi-list
    -- conflict; the user must explicitly remove the item from the other list
    -- first. Same-intent scopes (character + account whitelist) do not trip
    -- this and the add proceeds normally.
    local conflictName = EC_FindAddConflict(itemID, setName)
    if conflictName then
        if not quiet then
            PrintNicef(L["|cffff8888%s is already on %s. Remove it from there first.|r"], itemName, conflictName)
            PlaySound("igMainMenuOptionCheckBoxOff")
        else
            -- v2.51.0: silent quiet-mode refusals go to the diagnostic
            -- ring buffer so /ec bugreport can surface them. The caller
            -- (equipped-sync, upgrade-scan, equipment-set-sync,
            -- protection-refresh) gets a false return and no chat noise;
            -- the log is the audit trail.
            EC_LogSilentRefusal(itemID, setName, conflictName, label)
        end
        return false
    end
    t[itemID] = true
    if not quiet then
        PrintNicef(L["Added |cffb6ffb6%s|r to %s."], itemName, label)
    end
    -- Refresh the corresponding settings panel if it's been opened.
    local panelName = EC_CTX_PANEL_FOR[setName]
    if panelName then
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end
    -- Any list mutation can change a bag slot's would-sell verdict, so
    -- repaint the slot-border tints across already-decorated buttons. The
    -- helper is a no-op when the toggle is off or no buttons are tracked.
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    return true
end
-- Exposed to split files. Stage 8d uses NS.AddItemToList from the bag
-- context menu's "Add to ... list" row click handlers.
NS.AddItemToList = EC_AddItemToList

-- v2.13.0 ElvUI bag buttons: cursor-drop helper. Called by the bag-frame
-- buttons' OnReceiveDrag handler. Reads the cursor item via GetCursorInfo
-- (returns "item", itemID, itemLink for items), clears the cursor, and
-- routes through EC_AddItemToList so cross-list conflict guards and
-- duplicate checks apply. The label is the human-readable list name used
-- in the chat reply ("Sell List", "Keep List", "Delete List").
-- Hung off EC_compCache (rather than a file-scope local) to stay under
-- Lua 5.1's 200-locals-per-main-chunk cap.
function EC_compCache.handleItemDrop(setName, label)
    local cursorType, cursorID, cursorLink = GetCursorInfo()
    if cursorType ~= "item" then
        ClearCursor()
        return
    end
    local id = (type(cursorID) == "number") and cursorID or (cursorLink and tonumber(cursorLink:match("item:(%d+)")))
    ClearCursor()
    if not id then
        return
    end
    -- v2.13.3: removed redundant panel refresh - EC_AddItemToList already
    -- refreshes the panel via the same EC_CTX_PANEL_FOR lookup. The label
    -- arg is what the user sees in the chat reply.
    EC_AddItemToList(setName, id, label)
end

-- v2.13.0 ElvUI bag buttons: opens the EC options frame and jumps straight
-- to the panel that owns the requested list. Mirrors the slash-command's
-- double-call pattern (3.3.5a quirk: the first call only registers the
-- category, the second actually focuses it). Hung off EC_compCache so it
-- doesn't consume a main-chunk local slot.
function EC_compCache.openPanelToList(setName)
    local panelName = EC_CTX_PANEL_FOR and EC_CTX_PANEL_FOR[setName]
    if not panelName then
        return
    end
    NS.OpenOptionsPanel(panelName)
end

-- v2.13.0 ElvUI bag buttons. Three small icon buttons attached to the
-- top-right of ElvUI's main bag frame in Sell | Keep | Delete order.
-- Each button:
--   - Drag-drop: adds the cursor item to the corresponding EC list,
--     routed through EC_compCache.handleItemDrop -> EC_AddItemToList so cross-list
--     conflicts and dedupe checks apply.
--   - Right-click: jumps the EC options frame to the relevant list panel.
--   - Sell button only: left-click at a merchant fires a manual sell run
--     via the existing EbonClearance_ForceSell entry point.
-- Audience: ElvUI users on Project Ebonhold (a meaningful slice of the
-- player base). Non-ElvUI users see no change; the gate is the existence
-- of _G.ElvUI_ContainerFrame at call time. Idempotent: a guard on
-- EC_compCache.elvuiButtonsBuilt makes a second call cheap if anything
-- ever calls this twice.
function EC_compCache.buildElvUIBagButtons()
    if EC_compCache.elvuiButtonsBuilt then
        return
    end
    local bagFrame = _G.ElvUI_ContainerFrame
    if not bagFrame then
        return
    end
    EC_compCache.elvuiButtonsBuilt = true

    -- Shared backdrop for the three buttons. Subtle dark fill with a 1px
    -- mid-grey edge that brightens on hover; matches a sibling addon's
    -- bag buttons so users running both get a consistent visual.
    local function applyBackdrop(btn)
        btn:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            tileSize = 16,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        btn:SetBackdropColor(0, 0, 0, 0.6)
        btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    end

    -- Mints a button with shared chrome. iconHover is the (r,g,b) the icon
    -- texture vertex-tints to on hover; matches EC's tooltip color scheme
    -- (green for sell, orange for keep, red for delete).
    local function makeButton(name, parent, iconTexture, hoverR, hoverG, hoverB)
        local btn = CreateFrame("Button", name, parent)
        btn:SetSize(20, 20)
        applyBackdrop(btn)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
        icon:SetTexture(iconTexture)
        if iconTexture:find("Icons\\") then
            -- Icon textures need the 0.07/0.93 inset to crop the default
            -- Blizzard border; UI-GroupLoot textures don't.
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
        btn._icon = icon
        btn._hoverR, btn._hoverG, btn._hoverB = hoverR, hoverG, hoverB
        btn:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            self:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
            self._icon:SetVertexColor(1, 1, 1)
        end)
        return btn
    end

    -- Sell button (whitelist) - leftmost. Gold coin icon. Drag adds to
    -- whitelist; right-click opens Whitelist panel; left-click at a
    -- merchant triggers EbonClearance_ForceSell.
    local sellBtn =
        makeButton("EbonClearance_ElvUISellBtn", bagFrame, "Interface\\Icons\\INV_Misc_Coin_01", 0.71, 1.0, 0.71)
    sellBtn:SetPoint("TOPRIGHT", bagFrame, "TOPRIGHT", -98, -4)
    sellBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(L["|cff66ccff[EC]|r |cffb6ffb6Sell|r"], 0.71, 1, 0.71)
        GameTooltip:AddLine(L["Drop item to add to Sell List."], 1, 1, 1)
        GameTooltip:AddLine(L["Click at a vendor to start selling now."], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Right-click to open the Sell List panel."], 0.7, 0.7, 0.7)
        if not (MerchantFrame and MerchantFrame:IsShown()) then
            GameTooltip:AddLine(L["Not at a vendor."], 1, 0.4, 0.4)
        end
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    sellBtn:RegisterForDrag("LeftButton")
    sellBtn:RegisterForClicks("AnyUp")
    sellBtn:SetScript("OnReceiveDrag", function()
        EC_compCache.handleItemDrop("whitelist", "Sell List")
    end)
    sellBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            EC_compCache.openPanelToList("whitelist")
        elseif CursorHasItem() then
            EC_compCache.handleItemDrop("whitelist", "Sell List")
        elseif EbonClearance_ForceSell then
            EbonClearance_ForceSell()
        end
    end)

    -- Keep button (blacklist) - middle. Shield icon (semantically clearer
    -- than AutoDelete's chocolate box for "protected"). Drag adds to
    -- Blacklist (Keep); right-click opens the Blacklist panel.
    local keepBtn =
        makeButton("EbonClearance_ElvUIKeepBtn", bagFrame, "Interface\\Icons\\INV_Shield_06", 1.0, 0.78, 0.30)
    keepBtn:SetPoint("LEFT", sellBtn, "RIGHT", 4, 0)
    keepBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(L["|cff66ccff[EC]|r |cffffb84dKeep|r"], 1, 0.78, 0.30)
        GameTooltip:AddLine(L["Drop item to add to Keep List."], 1, 1, 1)
        GameTooltip:AddLine(L["Items here are never auto-sold or auto-deleted."], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Right-click to open the Keep List panel."], 0.7, 0.7, 0.7)
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    keepBtn:RegisterForDrag("LeftButton")
    keepBtn:RegisterForClicks("AnyUp")
    keepBtn:SetScript("OnReceiveDrag", function()
        EC_compCache.handleItemDrop("blacklist", "Keep List")
    end)
    keepBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            EC_compCache.openPanelToList("blacklist")
        elseif CursorHasItem() then
            EC_compCache.handleItemDrop("blacklist", "Keep List")
        end
    end)

    -- Delete button - rightmost. Red X icon (Blizzard's loot-pass texture,
    -- no icon-inset crop needed). Drag adds to delete list; right-click
    -- opens the Delete List panel.
    local delBtn = makeButton(
        "EbonClearance_ElvUIDeleteBtn",
        bagFrame,
        "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
        1.0,
        0.30,
        0.30
    )
    delBtn:SetPoint("LEFT", keepBtn, "RIGHT", 4, 0)
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(L["|cff66ccff[EC]|r |cffff4444Delete|r"], 1, 0.3, 0.3)
        GameTooltip:AddLine(L["Drop item to add to Delete List."], 1, 1, 1)
        GameTooltip:AddLine(L["Items here are auto-destroyed at any merchant visit."], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Right-click to open the Delete List panel."], 0.7, 0.7, 0.7)
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    delBtn:RegisterForDrag("LeftButton")
    delBtn:RegisterForClicks("AnyUp")
    delBtn:SetScript("OnReceiveDrag", function()
        EC_compCache.handleItemDrop("deleteList", "Delete List")
    end)
    delBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            EC_compCache.openPanelToList("deleteList")
        elseif CursorHasItem() then
            EC_compCache.handleItemDrop("deleteList", "Delete List")
        end
    end)
end

-- v2.37.4 (audit issue #4): the (affix-gated) and (Hit-proc) tags shown
-- on list-panel rows read ADB.affixedListedItems / ADB.chanceOnHitListedItems.
-- Those tables were stamped at add-time + on tooltip backfill but never
-- cleared on remove, so orphan entries accumulated over time. Clears both
-- meta entries when the itemID is absent from every list this character
-- can see (per-character sell/keep/delete + account sell). Alt characters
-- that still have the itemID on one of their lists will see the tag get
-- re-stamped on next tooltip hover via the EC_AnnotateTooltip backfill, so
-- this is safe to call from a single character's remove path.
local function EC_PruneSideMetaForItem(itemID)
    if not itemID or not ADB then
        return
    end
    if DB then
        if (DB.whitelist and DB.whitelist[itemID])
            or (DB.blacklist and DB.blacklist[itemID])
            or (DB.deleteList and DB.deleteList[itemID])
        then
            return
        end
    end
    if ADB.whitelist and ADB.whitelist[itemID] then
        return
    end
    if type(ADB.affixedListedItems) == "table" then
        ADB.affixedListedItems[itemID] = nil
    end
    if type(ADB.chanceOnHitListedItems) == "table" then
        ADB.chanceOnHitListedItems[itemID] = nil
    end
end
NS.PruneSideMetaForItem = EC_PruneSideMetaForItem

local function EC_RemoveItemFromList(setName, itemID, label)
    if not itemID then
        return
    end
    local t = EC_GetListTable(setName)
    if not t or not t[itemID] then
        return
    end
    t[itemID] = nil
    EC_PruneSideMetaForItem(itemID)
    -- v2.10.0: keep the auto-protected source map in lockstep so the
    -- tooltip annotation can never claim "(auto-protected: equipped)" for
    -- an item the user has explicitly removed. Cleared regardless of
    -- which list we removed from; blacklistAuto entries are only ever
    -- valid against the per-character Blacklist (Keep), but the no-op
    -- branch is fast on the other lists.
    if DB and type(DB.blacklistAuto) == "table" then
        DB.blacklistAuto[itemID] = nil
    end
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    PrintNicef(L["Removed |cffb6ffb6%s|r from %s."], itemName, label)
    -- Refresh the corresponding settings panel if it's been opened.
    local panelName = EC_CTX_PANEL_FOR[setName]
    if panelName then
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end
    -- Any list mutation can change a bag slot's would-sell verdict, so
    -- repaint the slot-border tints across already-decorated buttons. The
    -- helper is a no-op when the toggle is off or no buttons are tracked.
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
end
-- Exposed to split files. Stage 8d uses NS.RemoveItemFromList from the
-- bag context menu's "Remove from ... list" row click handlers.
NS.RemoveItemFromList = EC_RemoveItemFromList

-- v2.10.0: equipped-gear protection. Slot 19 (tabard) is cosmetic-only and
-- skipped. Slot 4 (shirt) USED to be skipped too but v2.50.2 pulled it out
-- of the skip: Project Ebonhold puts affix stat rolls onto shirts (Ironhide
-- IV etc.), so shirts are real gear that must land on the Keep List when
-- worn - otherwise runAutoMarkAffixDupes (v2.47.0) sees a soulbound affix
-- shirt in bags with no Keep signal and writes it to deleteList. Reported
-- by Bizzaro on behalf of Stickybackpack against v2.50.1. Helpers hang off
-- EC_compCache (same pattern as the v2.9.2 PROF_LOOT_SPELLS set) to keep
-- this addon under Lua 5.1's 200-local cap.
-- EC-TRAP: do NOT re-add "slot == 4" to the skip below. On PE the "cosmetic
-- only" assumption is false for shirts, and the auto-mark scan will destroy
-- affix shirts if the equipped-protection path skips them.

-- Auto-protect a single equipped slot. Routes through EC_AddItemToList in
-- quiet mode so the success / dedupe / conflict chat lines are suppressed
-- during the 19-slot one-shot sync; the reactive PLAYER_EQUIPMENT_CHANGED
-- caller prints one targeted line per add. Stamps DB.blacklistAuto on a
-- successful add so EC_AnnotateTooltip can attach the "(auto-protected:
-- equipped)" suffix at hover time. Returns true iff the slot was newly
-- added to the whitelist.
function EC_compCache.protectEquipSlot(slot)
    if not slot or slot == 19 then
        return false
    end
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
    if not link then
        return false
    end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then
        return false
    end
    -- v2.10.0: equipped gear lands on the BLACKLIST (Keep / do-not-sell)
    -- list, not the Whitelist (sell list). The Whitelist is the list of
    -- items the addon WILL sell - adding equipped gear there would mean
    -- "vendor everything I'm wearing the moment I swap to anything else".
    -- Blacklist is the protected list; that's the correct semantic for
    -- "remember what I'm wearing and don't auto-sell it".
    DB.blacklistAuto = DB.blacklistAuto or {}
    if EC_AddItemToList("blacklist", id, "Keep List", true) then
        -- v2.12.0: tag the entry with its origin so the tooltip can
        -- show "(Worn)" vs "(Upgrade)" instead of a generic
        -- Auto-Protected label. Legacy boolean-true entries from
        -- v2.10.0 / v2.11.0 fall back to the generic label at hover
        -- time.
        DB.blacklistAuto[id] = "equipped"
        return true
    elseif DB.blacklistAuto[id] then
        -- v2.12.0: item was already on the blacklist with an existing
        -- auto-tag ("upgrade" from autoProtectUpgrades, or "set" from
        -- v2.13.0's Equipment Manager protection). The user has now
        -- explicitly equipped it, so the more accurate tag is
        -- "equipped" - refresh in place. Manual blacklist entries
        -- (where blacklistAuto[id] is nil) stay untouched - the user
        -- added those deliberately.
        DB.blacklistAuto[id] = "equipped"
        return false
    end
    return false
end

-- One-shot sync helper. Called by the Blacklist (Keep) panel's
-- "Auto-protect equipped gear" checkbox when the user flips it from off to
-- on. Walks every gear slot once and prints a single summary line for the
-- whole batch. The reactive PLAYER_EQUIPMENT_CHANGED handler covers all
-- subsequent equipment swaps; this one-shot is only needed at toggle time.
function EC_compCache.syncEquipped()
    local added = 0
    for slot = 1, 19 do
        if EC_compCache.protectEquipSlot(slot) then
            added = added + 1
        end
    end
    if added > 0 then
        PrintNicef(L["|cffb6ffb6Added %d equipped item%s to your Keep List.|r"], added, added == 1 and "" or "s")
    else
        PrintNice(L["|cffaaaaaaYour equipped gear is already on the Keep List.|r"])
    end
end

-- v2.13.0 Equipment Manager protection. Adds an item from a saved equipment
-- set to the Keep list with origin tag "set". Routes through EC_AddItemToList
-- so cross-list conflicts and duplicate guards apply. Items already equipped
-- (tag "equipped") and looted upgrades (tag "upgrade") keep their existing
-- tag - "set" is the weakest tag and shouldn't downgrade more specific
-- ones. Manual blacklist entries (no auto-tag) are not touched. Returns
-- true iff a new entry was added.
function EC_compCache.protectEquipmentSetItem(itemID)
    -- Slot values 0 (empty) and 1 (ignore) come back from GetEquipmentSetItemIDs;
    -- itemID 1 is technically a real item but isn't auto-protectable equipment,
    -- so the > 1 check is safe in practice and dodges the ignore-marker overload.
    if not itemID or itemID <= 1 then
        return false
    end
    DB.blacklistAuto = DB.blacklistAuto or {}
    if EC_AddItemToList("blacklist", itemID, "Keep List", true) then
        DB.blacklistAuto[itemID] = "set"
        return true
    end
    -- Already on the blacklist. Do not promote or downgrade an existing
    -- tag - "equipped" / "upgrade" are more specific and should win.
    return false
end

-- One-shot sync helper. Called by the Blacklist (Keep) panel's
-- "Auto-protect equipment-manager sets" checkbox when the user flips it from
-- off to on, and by the EQUIPMENT_SETS_CHANGED reactive handler. Walks every
-- saved equipment set, dedupes itemIDs across sets via a session-local seen
-- map, and stamps each onto the Keep list. The Blizzard 3.3.5a Equipment
-- Manager API (GetNumEquipmentSets, GetEquipmentSetInfo, GetEquipmentSetItemIDs)
-- exists since 3.1.2; defensive nil-guards are kept for clients that
-- somehow lack it. `silent` skips the chat summary - used by the live
-- EQUIPMENT_SETS_CHANGED path so set-edits don't spam.
function EC_compCache.syncEquipmentSets(silent)
    if not (GetNumEquipmentSets and GetEquipmentSetInfo and GetEquipmentSetItemIDs) then
        return 0
    end
    local n = GetNumEquipmentSets()
    if not n or n == 0 then
        if not silent then
            PrintNice(
                L["|cffaaaaaaNo equipment sets saved. Use the Blizzard Equipment Manager to create one, then re-tick this option.|r"]
            )
        end
        return 0
    end
    -- v2.50.2: reuse this walk to rebuild EC_compCache.equipmentSetIDs, a
    -- session-scoped { [itemID] = true } cache consumed by runAutoMarkAffixDupes
    -- and runAutoMarkResilience so items in any saved equipment set are never
    -- auto-marked, even if the Keep-List stamp is delayed or silently refused
    -- by EC_FindAddConflict (see the shirt-loss root-cause note in v2.50.2's
    -- CHANGELOG). Wipe the cache upfront so removed set members don't linger.
    -- The same table doubles as the dedupe map for the outer walk (replacing
    -- the previous file-local `seen`), so populating the cache costs nothing.
    -- Cache rebuild runs even when DB.autoProtectEquipmentSets is off - the
    -- scan-side rescue MUST honour set membership as user intent regardless
    -- of whether the user opted into the automatic Keep-List stamping.
    EC_compCache.equipmentSetIDs = EC_compCache.equipmentSetIDs or {}
    wipe(EC_compCache.equipmentSetIDs)
    local seen = EC_compCache.equipmentSetIDs
    local stampToKeep = DB and DB.autoProtectEquipmentSets
    local added, sets = 0, 0
    local buf = {}
    for i = 1, n do
        local name = GetEquipmentSetInfo(i)
        if name then
            sets = sets + 1
            for k in pairs(buf) do
                buf[k] = nil
            end
            GetEquipmentSetItemIDs(name, buf)
            for _, id in pairs(buf) do
                if id and id > 1 and not seen[id] then
                    seen[id] = true
                    if stampToKeep and EC_compCache.protectEquipmentSetItem(id) then
                        added = added + 1
                    end
                end
            end
        end
    end
    if not silent then
        if added > 0 then
            PrintNicef(
                L["|cffb6ffb6Auto-protected %d item%s from %d equipment set%s.|r"],
                added,
                added == 1 and "" or "s",
                sets,
                sets == 1 and "" or "s"
            )
        else
            PrintNicef(
                L["|cffaaaaaaScanned %d equipment set%s; all items already on the keep list.|r"],
                sets,
                sets == 1 and "" or "s"
            )
        end
    end
    return added
end

-- v2.11.0 auto-protect upgraded gear (BAG_UPDATE-driven). Closes the gap
-- left by v2.10.0's PLAYER_EQUIPMENT_CHANGED-driven path: that path only
-- protected the *previously-equipped* item the moment the user swaps in
-- an upgrade. A higher-iLvl drop sitting in bags waiting to be equipped
-- was unprotected, and any active per-rarity iLvl-cap rule could vendor
-- it on the next merchant visit. The new path scans bag items on every
-- BAG_UPDATE, computes their slot type and base iLvl from GetItemInfo,
-- and stamps the Keep list when a bag item's iLvl exceeds the equipped
-- item in any of its candidate slots. Multi-slot equipLocs (rings,
-- trinkets, weapons) compare against the LOWER of the two equipped
-- iLvls so any genuine upgrade triggers.
--
-- Cost: GetItemInfo + a few inventory link reads per never-seen-before
-- itemID. EC_compCache.upgradeProcessed dedupes per-itemID for the
-- session - a /reload reseeds. EC_AddItemToList's quiet+dedupe path
-- short-circuits items already on the blacklist, so the only chat
-- output is the per-add notice.
EC_compCache.INVTYPE_SLOTS = {
    INVTYPE_HEAD = { 1 },
    INVTYPE_NECK = { 2 },
    INVTYPE_SHOULDER = { 3 },
    INVTYPE_CHEST = { 5 },
    INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_HOLDABLE = { 17 },
    INVTYPE_SHIELD = { 17 },
    INVTYPE_RANGED = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 },
    INVTYPE_THROWN = { 18 },
    INVTYPE_RELIC = { 18 },
}

EC_compCache.upgradeProcessed = {}

function EC_compCache.getEquippedILvl(slotID)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slotID)
    if not link then
        return 0
    end
    local _, _, _, iLvl = GetItemInfo(link)
    return iLvl or 0
end

-- Lowest equipped iLvl across the given candidate slots, skipping empty
-- ones; nil when none are filled. Shared by the upgrade sweep (cleanup +
-- new-item) and the stale-upgrade report. NOTE: isDowngradeVsEquipped does
-- NOT use this - it treats an empty candidate slot as "don't auto-sell"
-- (returns early), which is a different rule.
function EC_compCache.getLowestEquippedILvl(slots)
    -- v2.59.10 (bug-hunt): defensive nil-guard. Every current caller
    -- guards, but Lua 5.1 crashes on `ipairs(nil)` and a future caller
    -- passing nil (e.g. equipLoc that doesn't map to INVTYPE_SLOTS)
    -- would take down the sell path. Return nil consistently.
    if not slots then
        return nil
    end
    local lowest = nil
    for _, sid in ipairs(slots) do
        local eq = EC_compCache.getEquippedILvl(sid)
        if eq > 0 and (lowest == nil or eq < lowest) then
            lowest = eq
        end
    end
    return lowest
end

-- v2.12.0 mirror of checkBagsForUpgrades' iLvl-vs-equipped comparison,
-- inverted: returns true iff a looted item's iLvl is strictly LESS than
-- the lowest populated equipped iLvl across the item's candidate slots.
-- Drives the per-rarity "Use equipped iLvl" sell mode in EC_IsSellable.
--
-- Multi-slot conservative rule: a ring / trinket / 1H weapon sells only
-- when worse than EVERY equipped slot - if any slot would treat it as
-- an upgrade, keep it. Empty slots are skipped entirely (the user might
-- want to fill that slot with the looted item, so we don't auto-sell).
--
-- Trade goods, reagents, consumables, and quest items have no equipLoc
-- in EC_compCache.INVTYPE_SLOTS, so they're naturally protected by the
-- early-return below.
function EC_compCache.isDowngradeVsEquipped(itemID, lootedILvl, equipLoc)
    -- v2.12.0+ returns (boolean, reason) so the tooltip annotation can
    -- distinguish "rule fired and decided keep" from "rule short-
    -- circuited on an empty slot". EC_IsSellable's call site only reads
    -- the boolean (Lua multi-return is transparent there).
    -- reason values:
    --   "not_equippable" - missing itemID / iLvl / equipLoc
    --   "no_slot_mapping" - equipLoc not in INVTYPE_SLOTS (relics, bags, etc.)
    --   "empty_slot"      - any candidate slot was empty; rule bailed without
    --                       comparing iLvls so the looted item could fill it
    --   "below_lowest"    - looted iLvl is below the lowest populated slot
    --                       (this is the only reason the boolean is true)
    --   "at_or_above"     - looted iLvl met or exceeded the lowest populated
    --                       slot's iLvl - actual iLvl comparison happened
    if not itemID or not lootedILvl or lootedILvl <= 0 then
        return false, "not_equippable"
    end
    if not equipLoc or equipLoc == "" then
        return false, "not_equippable"
    end
    local slots = EC_compCache.INVTYPE_SLOTS[equipLoc]
    if not slots then
        return false, "no_slot_mapping"
    end
    -- v2.33.x: 2H-aware narrowing for INVTYPE_WEAPON. A 1H weapon's
    -- candidate slots are {16, 17} but the offhand (17) is LOCKED EMPTY
    -- when the player wields a 2H - it's not an unfilled "could fill
    -- this" slot, so the empty_slot bailout below would falsely keep
    -- every 1H in bags (reported by "Perfect Bidoof"). When the main
    -- hand holds an INVTYPE_2HWEAPON, narrow the candidate slots to
    -- {16} only so the comparison happens against the equipped 2H.
    -- v2.45.1: mirror this for OFFHAND equipLocs (SHIELD / HOLDABLE /
    -- WEAPONOFFHAND). When MH is a 2H, slot 17 is locked empty and an
    -- offhand item can't actually fill it - the player would have to
    -- swap out their 2H first. Reported by Zukii: an offhand looted
    -- while a staff was equipped showed "Keep (Green, possible
    -- upgrade)" because empty_slot returned not_a_downgrade. The
    -- comparison-against-the-2H baseline is what real players want:
    -- low-level offhand drops vendor when the player has chosen 2H,
    -- and only items genuinely above the 2H's iLvl get the upgrade
    -- flag (still rare in practice but theoretically right).
    if equipLoc == "INVTYPE_WEAPON"
        or equipLoc == "INVTYPE_SHIELD"
        or equipLoc == "INVTYPE_HOLDABLE"
        or equipLoc == "INVTYPE_WEAPONOFFHAND"
    then
        local mhLink = GetInventoryItemLink and GetInventoryItemLink("player", 16)
        if mhLink then
            local _, _, _, _, _, _, _, _, mhEquipLoc = GetItemInfo(mhLink)
            if mhEquipLoc == "INVTYPE_2HWEAPON" then
                slots = { 16 }
            end
        end
    end
    local lowestEquipped = nil
    for _, sid in ipairs(slots) do
        local eq = EC_compCache.getEquippedILvl(sid)
        if eq <= 0 then
            return false, "empty_slot"
        end
        if lowestEquipped == nil or eq < lowestEquipped then
            lowestEquipped = eq
        end
    end
    if lowestEquipped == nil then
        return false, "no_slot_mapping"
    end
    if lootedILvl < lowestEquipped then
        return true, "below_lowest"
    end
    return false, "at_or_above"
end

-- v2.59.9: mirror of checkBagsForUpgrades' Keep-Upgrade stamp condition.
-- Returns true iff the item's iLvl is STRICTLY GREATER than the lowest
-- populated equipped iLvl across the item's candidate slots. Empty slots
-- are SKIPPED (an empty ring-2 slot doesn't disqualify a ring-in-bags from
-- being an upgrade over the populated ring-1). Feeds the affix-sale veto
-- so autoDupePass / affixRankPass never sell an item the auto-upgrade sweep
-- would have stamped, regardless of the Keep List entry's state - Serv
-- report: engraving a known-dupe affix onto an upgrade ring flipped its
-- verdict to SELL because the Keep-Upgrade Keep List entry became stale
-- post-engrave. This check is Keep-List-independent so it survives that
-- class of staleness. Different from isDowngradeVsEquipped: THAT bails on
-- empty slots (conservatively keeps items that could fill the empty slot);
-- THIS treats empty slots as non-participating in the "is this an upgrade"
-- question (mirroring how checkBagsForUpgrades decides what to stamp).
function EC_compCache.isUpgradeVsEquipped(itemID, ilvl, equipLoc)
    if not itemID or not ilvl or ilvl <= 0 then
        return false
    end
    if not equipLoc or equipLoc == "" then
        return false
    end
    local slots = EC_compCache.INVTYPE_SLOTS[equipLoc]
    if not slots then
        return false
    end
    -- 2H narrowing mirror: if MH is 2H, offhand slot 17 is locked empty
    -- and shouldn't be treated as a fillable candidate. Same rule
    -- isDowngradeVsEquipped uses above; keep in lockstep or a 1H upgrade
    -- past a 2H would be missed.
    if equipLoc == "INVTYPE_WEAPON"
        or equipLoc == "INVTYPE_SHIELD"
        or equipLoc == "INVTYPE_HOLDABLE"
        or equipLoc == "INVTYPE_WEAPONOFFHAND"
    then
        local mhLink = GetInventoryItemLink and GetInventoryItemLink("player", 16)
        if mhLink then
            local _, _, _, _, _, _, _, _, mhEquipLoc = GetItemInfo(mhLink)
            if mhEquipLoc == "INVTYPE_2HWEAPON" then
                slots = { 16 }
            end
        end
    end
    local lowestEquipped = EC_compCache.getLowestEquippedILvl(slots)
    if not lowestEquipped then
        return false
    end
    return ilvl > lowestEquipped
end

-- v2.57.2 SAFETY: is an affixed item at or below the iLvl ceiling its rarity's
-- quality rule sets? The affix sell paths (the affix-rank floor and "Allow
-- selling affixes you already have") must respect this ceiling, so a high-iLvl
-- item the user set a cap to protect is NOT sold just because they already own
-- its affix. Near item-loss report (Bizzaro): an ilvl-277 Epic sold under an
-- Epic cap of 250 because the affix was a known dupe.
--
-- Returns true (affix sale allowed) when the rarity rule is disabled or set to
-- "sell all" (cap 0) - the affix rules stay standalone there, as before.
-- Otherwise it applies the SAME iLvl gate qualityPass uses (dynamic equipped-
-- iLvl comparison, or fixed maxILvl cap). Shared by EC_IsSellable,
-- describeSellability, and the tooltip so all three agree on the ceiling.
--
-- v2.59.9: also vetoes the sale unconditionally when the item is an iLvl
-- upgrade over equipped AND autoProtectUpgrades is on. Runs BEFORE the
-- rule-enabled early-return so it applies even when the rarity rule is
-- disabled - the "don't auto-sell my upgrades" invariant is not a
-- rarity-rule-conditional invariant.
function EC_compCache.affixSaleWithinCeiling(quality, ilvl, equipLoc, itemID)
    local DB = NS.DB
    if DB and DB.autoProtectUpgrades
        and EC_compCache.isUpgradeVsEquipped
        and EC_compCache.isUpgradeVsEquipped(itemID, ilvl, equipLoc)
    then
        return false
    end
    local rule = (quality and quality >= 1 and quality <= 4 and DB and DB.qualityRules) and DB.qualityRules[quality]
    if not (rule and rule.enabled) then
        return true
    end
    if rule.useEquippedILvl then
        return EC_compCache.isDowngradeVsEquipped(itemID, ilvl, equipLoc) and true or false
    end
    local cap = rule.maxILvl or 0
    if cap == 0 then
        return true
    end
    local hasVisibleILvl = equipLoc and equipLoc ~= "" and ilvl and ilvl > 0
    return (hasVisibleILvl and ilvl <= cap) and true or false
end

function EC_compCache.checkBagsForUpgrades()
    if not DB or not DB.autoProtectUpgrades then
        return
    end
    -- Skip while a vendor cycle is mid-flight: the worker queue was
    -- built before any add we'd make now, so a fresh blacklist stamp
    -- wouldn't influence the current run anyway. Next BAG_UPDATE post-
    -- MERCHANT_CLOSED picks up the same items cleanly.
    if EC_compCache.vendorRunning then
        return
    end
    -- v2.33.x: re-evaluate existing "upgrade"-tagged Keep List entries
    -- and release ones that are no longer above the currently equipped
    -- iLvl. Without this, an item added when the player had a low-iLvl
    -- weapon equipped (e.g. a starter weapon during early levelling)
    -- stays on the Keep List forever even after the player upgrades
    -- their gear past it. The `/ec clean upgrades apply` slash command
    -- exists for manual cleanup but users shouldn't have to remember
    -- it - the path that ADDED the entry should clean its own stale
    -- entries. Only touches autoTag "upgrade" entries; manual Keep
    -- List adds (no autoTag) and "equipped" / "set" autoTags are left
    -- alone (those have their own reactive sync paths).
    if DB.blacklistAuto then
        for itemID, tag in pairs(DB.blacklistAuto) do
            if tag == "upgrade" then
                -- v2.44.0: class-restriction self-heal. Pre-v2.44.0 the
                -- upgrade sweep didn't check IsUsableItem, so a Druid
                -- could end up with bows / Mages with relics / etc.
                -- stamped as "upgrade" against the relic / ranged slot.
                -- Strip those stale entries on every sweep. Only acts on
                -- an explicit `false` from IsUsableItem (class veto) -
                -- `nil` (uncached) leaves the entry alone to avoid a
                -- false self-heal during item-cache warmup.
                local unusable = IsUsableItem and IsUsableItem(itemID) == false
                if unusable then
                    if DB.blacklist then
                        DB.blacklist[itemID] = nil
                    end
                    DB.blacklistAuto[itemID] = nil
                    if EC_compCache.upgradeProcessed then
                        EC_compCache.upgradeProcessed[itemID] = nil
                    end
                else
                    local _, _, _, iLvl, _, _, _, _, equipLoc = GetItemInfo(itemID)
                    local slots = equipLoc and EC_compCache.INVTYPE_SLOTS[equipLoc]
                    -- v2.59.10 (bug-hunt): 2H narrowing mirror. See the
                    -- addition path below + isDowngradeVsEquipped +
                    -- isUpgradeVsEquipped for the shared rationale.
                    if slots and (equipLoc == "INVTYPE_WEAPON"
                        or equipLoc == "INVTYPE_SHIELD"
                        or equipLoc == "INVTYPE_HOLDABLE"
                        or equipLoc == "INVTYPE_WEAPONOFFHAND")
                    then
                        local mhLink = GetInventoryItemLink and GetInventoryItemLink("player", 16)
                        if mhLink then
                            local _, _, _, _, _, _, _, _, mhEquipLoc = GetItemInfo(mhLink)
                            if mhEquipLoc == "INVTYPE_2HWEAPON" then
                                slots = { 16 }
                            end
                        end
                    end
                    if iLvl and iLvl > 0 and slots then
                        local lowestEquipped = EC_compCache.getLowestEquippedILvl(slots)
                        -- Remove only when a slot is actually populated and
                        -- the item's iLvl is at or below it. If every
                        -- candidate slot is empty, be conservative and keep
                        -- the entry - the next cycle will re-evaluate once
                        -- gear comes back.
                        if lowestEquipped and iLvl <= lowestEquipped then
                            if DB.blacklist then
                                DB.blacklist[itemID] = nil
                            end
                            DB.blacklistAuto[itemID] = nil
                            -- Clear the per-session memo so a future gear
                            -- downgrade can re-add this item via the
                            -- new-entry loop below.
                            if EC_compCache.upgradeProcessed then
                                EC_compCache.upgradeProcessed[itemID] = nil
                            end
                        end
                    end
                end
            end
        end
    end
    -- v2.59.0: iterate the shared flush snapshot (or a fresh one when
    -- called outside the flush, e.g. the Protection panel toggle). The
    -- upgradeProcessed memo and every action below are itemID-keyed list
    -- writes, so snapshot iteration needs no live slot re-verify here.
    local snap = EC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        do -- scoping block keeps the old two-level loop body untouched
            local itemID = snap.entries[i].itemID
            if itemID and not EC_compCache.upgradeProcessed[itemID] then
                EC_compCache.upgradeProcessed[itemID] = true
                -- v2.44.0: skip items the player's class can't use. A
                -- Druid will never equip a bow; a Mage will never use
                -- a relic - they shouldn't be polluting the Keep List
                -- as "upgrade" candidates. Real player report from
                -- Murlocked. IsUsableItem returns false on a class
                -- restriction; `nil` (uncached) doesn't match and lets
                -- the iLvl logic still run on the warmup pass.
                if IsUsableItem and IsUsableItem(itemID) == false then -- luacheck: ignore 542
                    -- Intentional no-op fall-through to the next slot.
                    -- upgradeProcessed[itemID] stays true so we don't
                    -- re-check every BAG_UPDATE; /reload reseeds the
                    -- cache if the player's class somehow changes.
                elseif not (DB.blacklist and DB.blacklist[itemID]) then
                    local _, _, _, iLvl, _, _, _, _, equipLoc = GetItemInfo(itemID)
                    local slots = equipLoc and EC_compCache.INVTYPE_SLOTS[equipLoc]
                    -- v2.59.10 (bug-hunt): 2H narrowing mirror. Same rule
                    -- isDowngradeVsEquipped + isUpgradeVsEquipped use:
                    -- when the player wields a 2H, offhand slot 17 is
                    -- LOCKED empty and shouldn't be treated as a fillable
                    -- candidate slot. Without this narrowing, an
                    -- INVTYPE_SHIELD / HOLDABLE / WEAPONOFFHAND / 1H-
                    -- INVTYPE_WEAPON in bags gets its upgrade check against
                    -- slot 17's empty iLvl (0) which mass-stamps every
                    -- offhand item as an upgrade. Pre-v2.59.10 the drift
                    -- was safe (over-protect side of the affix-sale veto)
                    -- but caused inconsistency between the three predicates.
                    if slots and (equipLoc == "INVTYPE_WEAPON"
                        or equipLoc == "INVTYPE_SHIELD"
                        or equipLoc == "INVTYPE_HOLDABLE"
                        or equipLoc == "INVTYPE_WEAPONOFFHAND")
                    then
                        local mhLink = GetInventoryItemLink and GetInventoryItemLink("player", 16)
                        if mhLink then
                            local _, _, _, _, _, _, _, _, mhEquipLoc = GetItemInfo(mhLink)
                            if mhEquipLoc == "INVTYPE_2HWEAPON" then
                                slots = { 16 }
                            end
                        end
                    end
                    if iLvl and iLvl > 0 and slots then
                        -- For multi-slot equipLocs (rings, trinkets,
                        -- 1H weapons), compute the LOWEST iLvl among
                        -- the populated candidate slots. Empty slots
                        -- are ignored - otherwise an empty ring-2 slot
                        -- (iLvl 0) would suppress upgrade detection
                        -- against an iLvl-250 ring-1.
                        local lowestEquipped = EC_compCache.getLowestEquippedILvl(slots)
                        -- v2.12.0: require at least one populated slot to
                        -- give us a real baseline. The pre-fix behaviour
                        -- fell back to threshold = 0 when every candidate
                        -- slot was empty (e.g. logging in with no weapons),
                        -- which mass-stamped every iLvl > 0 item in bags
                        -- as an "upgrade" - polluting the Keep list with
                        -- dozens of low-iLvl daggers / spare gear that
                        -- weren't actually upgrades against anything. Now
                        -- if no slot is populated we skip this iteration
                        -- entirely; we'll re-check this itemID when
                        -- upgradeProcessed is reset (a /reload). When the
                        -- user equips something later, PLAYER_EQUIPMENT_
                        -- CHANGED + autoAddEquipped covers the equipped
                        -- side; subsequent BAG_UPDATEs cover the bag side
                        -- once at least one slot is populated.
                        if lowestEquipped and iLvl > lowestEquipped then
                            if EC_AddItemToList("blacklist", itemID, "Keep List", true) then
                                DB.blacklistAuto = DB.blacklistAuto or {}
                                -- v2.12.0: origin tag for tooltip fork.
                                DB.blacklistAuto[itemID] = "upgrade"
                                local name = GetItemInfo(itemID) or ("Item:" .. itemID)
                                PrintNicef(L["|cffb6ffb6Kept %s (looks like an upgrade).|r"], name)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- The bag-item Alt+Right-Click context menu (EC_CTX_ROWS,
-- EC_BuildCtxFrame, EC_ShowItemContextMenu, EC_InstallBagContextHookOnce)
-- lives in EbonClearance_BagContextMenu.lua after Stage 8d of the file
-- split. Exposed as NS.InstallBagContextHookOnce for the ADDON_LOADED
-- branch in this file to call.


-- ===========================================================================

-- Pet stuck detection + auto-loot cycle bag monitoring
local EC_petCheckFrame = CreateFrame("Frame")

-- Pet-check OnUpdate is split into named helpers below. The dispatch itself
-- (at the bottom) handles three per-frame timer countdowns and one 5 s-gated
-- tick body. See docs/CODE_REVIEW.md item 3.
--
-- The three timer-countdown helpers return true if they consumed the tick
-- (caller should return early), or false to fall through.

-- 1.5 s post-dismiss delay before summoning the Goblin Merchant. The dismiss
-- has to land server-side before CallCompanion, otherwise the slot is still
-- occupied by the Scavenger and the call no-ops. v2.6.2 adds a cast-busy
-- gate: if the timer fires while the player is mid-cast / channeling /
-- moving, push the timer 0.5 s and try again so the summon doesn't get
-- silently rejected by the spell system.
local function EC_TickGoblinSummon(elapsed)
    if not EC_summonGoblinPending then
        return false
    end
    EC_summonGoblinTimer = EC_summonGoblinTimer - elapsed
    if EC_summonGoblinTimer <= 0 then
        if EC_IsPlayerBusy() then
            -- Defer 0.5 s and let the next tick re-evaluate. Stays pending
            -- so the OnUpdate will keep entering this branch until a clear
            -- cast/movement window opens.
            EC_summonGoblinTimer = 0.5
            return true
        end
        EC_summonGoblinPending = false
        local idx = FindGoblinMerchantIndex()
        if idx then
            CallCompanion("CRITTER", idx)
            EC_goblinRetryCount = EC_goblinRetryCount + 1
            EC_targetGoblinPending = true
            EC_targetGoblinTimer = 2.0
        else
            PrintNice(L["|cffff4444Goblin Merchant not found in companion list!|r"])
            EC_compCache.lootCycleState = STATE.LOOTING
        end
    end
    return true
end

-- 2.0 s post-summon verify: GetCompanionInfo lags the actual summon, so we
-- wait before checking whether the merchant came out, then arm the 8 s
-- "right-click me" reminder if it did. v2.6.2 expanded the retry budget
-- from 1 to EC_GOBLIN_MAX_RETRIES attempts: under heavy combat the bare
-- GCD from instant-cast rotations can swallow several attempts before
-- one lands. On a miss we re-arm EC_summonGoblinPending with a 0.5 s
-- delay so the next attempt routes through EC_TickGoblinSummon's
-- cast-busy gate before firing CallCompanion.
local function EC_TickGoblinTarget(elapsed)
    if not EC_targetGoblinPending then
        return false
    end
    EC_targetGoblinTimer = EC_targetGoblinTimer - elapsed
    if EC_targetGoblinTimer <= 0 then
        EC_targetGoblinPending = false
        local idx, nowSummoned = FindGoblinMerchantIndex()
        if nowSummoned then
            EC_goblinRetryCount = 0
            PrintNicef(
                L["|cff00ff00Goblin Merchant summoned|r - press %s or right-click to sell."],
                EC_FormatTargetMerchantBinding()
            )
            EC_merchantReminderPending = true
            EC_merchantReminderTimer = 8.0
        elseif idx and EC_goblinRetryCount < EC_GOBLIN_MAX_RETRIES then
            -- v2.11.0: nudge the user when we're about to fire the last
            -- attempt. Two missed retries means the previous CallCompanions
            -- bounced off the GCD - the v2.11.0 GCD-aware busy gate covers
            -- the common case but can't see haste-reduced GCDs or any other
            -- server-side reject reason. Telling the user gives them a
            -- ~2.5 s window (0.5 s pre-fire + 2.0 s verify) to pause their
            -- rotation so the next CallCompanion catches a clear window.
            -- Only fires once per cycle (transition from N-1 -> N retries).
            if EC_goblinRetryCount == EC_GOBLIN_MAX_RETRIES - 1 then
                PrintNice(
                    L["|cffffb84dGoblin Merchant retrying. Hold off your rotation briefly so the summon can land.|r"]
                )
            end
            -- Re-route through the summon path so the next CallCompanion
            -- waits for a clear cast/movement window first.
            EC_summonGoblinPending = true
            EC_summonGoblinTimer = 0.5
        else
            EC_goblinRetryCount = 0
            PrintNice(L["|cffff4444Goblin Merchant failed to summon. Resuming looting.|r"])
            EC_compCache.lootCycleState = STATE.LOOTING
        end
    end
    return true
end

-- 8 s nudge for users who summoned the merchant but then got distracted.
-- Falls through (returns false) so the 5 s-gated body still runs this frame.
local function EC_TickMerchantReminder(elapsed)
    if not EC_merchantReminderPending then
        return false
    end
    EC_merchantReminderTimer = EC_merchantReminderTimer - elapsed
    if EC_merchantReminderTimer <= 0 then
        EC_merchantReminderPending = false
        if EC_compCache.lootCycleState == STATE.WAITING_MERCHANT then
            PrintNice(L["|cffffff00Right-click the Goblin Merchant to open the vendor window.|r"])
        end
    end
    return false
end

-- Reconcile cycle state with companion-out reality: if the Scavenger is
-- already out at IDLE, advance to LOOTING so the auto-loot cycle picks up.
local function EC_AutoLootStateSync()
    if not (DB.autoLootCycle and EC_compCache.lootCycleState == STATE.IDLE) then
        return
    end
    local num = GetNumCompanions("CRITTER")
    for i = 1, (num or 0) do
        local _, creatureName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if creatureName == PET_NAME and isSummoned then
            EC_compCache.lootCycleState = STATE.LOOTING
            break
        end
    end
end

-- Secondary stuck-detection signal. Movement-time alone misses cases where
-- the player kills and loots in place (channels, melee, kiting in tight
-- circles): the Scavenger gets left behind on terrain but the accumulator
-- never accrues. This signal fires when the player has looted at least
-- MIN_LOOTS corpses inside the WINDOW and the Scavenger has not been heard
-- to speak since the oldest of those loots. Prunes the loot ring as a side
-- effect on every check, so it cannot grow unboundedly.
local function EC_IsLootSilenceStuck()
    -- v2.10.0 silent-realm guard. The signal assumes the Scavenger pet
    -- audibly chats on each loot pickup. On Project Ebonhold the pet's
    -- chat events don't reliably reach the chat filter (verified: a
    -- user's heavy-farming chat log shows zero pet-speech messages
    -- across an entire session). Without this guard the on-summon
    -- synthetic refresh of EC_compCache.lastScavSpokeAt resets the silence clock
    -- at every dismiss-and-resummon cycle, producing a feedback loop
    -- where the signal fires every ~60 s of farming. Gating on
    -- EC_compCache.scavSpeechEverHeard - which only flips true via a
    -- real chat-filter match, never via the on-summon refresh - makes
    -- the signal self-disable on silent realms while preserving the
    -- v2.7.0 / v2.8.0 behaviour for any future realm where the pet
    -- does broadcast normally. Movement-time stuck detection
    -- (EC_STUCK_MOVEMENT_THRESHOLD, 180 s) remains the catch-all.
    if not EC_compCache.scavSpeechEverHeard then
        return false
    end
    local WINDOW, MIN_LOOTS = 60, 2
    local now = GetTime()
    local kept = {}
    for i = 1, #EC_recentLootTimes do
        local t = EC_recentLootTimes[i]
        if (now - t) <= WINDOW then
            kept[#kept + 1] = t
        end
    end
    EC_recentLootTimes = kept
    if #kept < MIN_LOOTS then
        return false
    end
    return EC_compCache.lastScavSpokeAt < kept[1]
end

-- Stuck-Scavenger handling. Two signals OR'd together:
--   1. EC_scavMovementAccum >= EC_STUCK_MOVEMENT_THRESHOLD - the player has
--      moved enough that the pet should have caught up but hasn't (since
--      the OnUpdate accumulator only ticks while the pet is flagged out).
--   2. EC_IsLootSilenceStuck() - the player kept looting while the pet went
--      silent, suggesting it's geographically lost even though the player
--      isn't moving much.
-- On either signal the Scavenger is dismissed; the next 5 s tick re-summons
-- at the player's current position via EC_TryResummonScavenger.
-- Returns true if the Scavenger is out (caller bails out of re-summon path).
local function EC_HandleScavengerOut(scavengerOut)
    if not scavengerOut then
        return false
    end
    local stuckByMovement = EC_scavMovementAccum >= EC_STUCK_MOVEMENT_THRESHOLD
    local stuckByLootSilence = EC_IsLootSilenceStuck()
    if stuckByMovement or stuckByLootSilence then
        EC_compCache.addonDismissed = true
        -- v2.65.1: count every stuck-signal firing regardless of announce
        -- cooldown, so /ec bugreport shows the true recovery cadence.
        EC_compCache.scavRecoveryFires = (EC_compCache.scavRecoveryFires or 0) + 1
        EC_compCache.lastScavRecoveryAt = GetTime()
        -- v2.65.1: rate-limit the announce so rough-terrain farming
        -- doesn't spam the chat every 10-15 s. Silent dismiss+resummon
        -- inside the cooldown; still audible on the first fire per
        -- window so the player knows why the pet just teleported to
        -- their feet. Only arm pendingAnnounce when we're announcing
        -- this recovery - silent-cooldown recoveries suppress both
        -- "went quiet" AND "resummoned" so the two prints stay paired.
        local now = GetTime()
        local cooldown = EC_compCache.scavRecoveryAnnounceCooldown or 60
        local announce = (now - (EC_compCache.lastScavRecoveryAnnounceAt or 0)) >= cooldown
        if announce then
            EC_compCache.lastScavRecoveryAnnounceAt = now
            EC_compCache.pendingAnnounce = true
            if stuckByMovement then
                PrintNice(L["|cffffff00Scavenger fell behind. Resummoning when you stop moving.|r"])
            else
                PrintNice(L["|cffffff00Scavenger went quiet during looting. Resummoning when you stop moving.|r"])
            end
        end
        EC_scavMovementAccum = 0
        EC_recentLootTimes = {}
        DismissGreedyScavenger()
    end
    return true
end

-- Re-summon the Scavenger if and only if we (this addon) dismissed it.
-- Manual portrait dismisses leave EC_addonDismissed=false, so this gate
-- naturally honours them. Concurrent companions (bank mule, mailbox)
-- suppress; the 10 s mount-dismiss cooldown suppresses.
--
-- Cast-busy gate (v2.6.2, broadened from the v2.6.1 movement-only gate):
-- on Project Ebonhold a CRITTER summon issued while the player is moving
-- spawns the pet as a zombie that never follows; under heavy combat,
-- summons issued mid-cast or mid-channel get silently rejected by the
-- spell system (it lands inside someone else's cast / GCD slot). Both
-- failure modes are handled by deferring until EC_IsPlayerBusy() is
-- false. EC_addonDismissed stays true while we wait, so the next tick
-- after the player is clear will fire the summon.
--
-- EC_addonDismissed is NOT cleared here either. CallCompanion can also
-- be silently rejected (separate from the zombie case) and we want the
-- retry budget. EC_PetCheckTick clears the flag when it observes
-- scavengerOut=true on the next enumeration -- the canonical
-- "summon landed" signal.
local function EC_TryResummonScavenger(greedyIndex, anyPetOut, goblinStillOut)
    -- v2.33.x: defensive DB.summonGreedy gate. The only caller today is
    -- EC_PetCheckTick which already gates on DB.summonGreedy, so this
    -- check is belt-and-braces. Added in response to SLG's report of
    -- post-merchant summons firing with the option unchecked - static
    -- analysis of v2.33.0 found no bypass path, but a defensive gate
    -- inside the function makes the contract impossible to violate
    -- from a future caller that forgets the gate. ADDON_GUIDE.md's
    -- "EC_TryResummonScavenger only fires when EC_addonDismissed ==
    -- true" invariant is now extended: also only fires when the user
    -- has the summon option on.
    if not DB or not DB.summonGreedy then
        return
    end
    -- v2.9.0: honour the user-dismiss-vs-leash grace window. If a recent
    -- transition was classified as a manual portrait dismiss, suppress the
    -- restore until the grace expires so the addon does not fight the user.
    -- Worst case is a 30 s gap before auto-recovery resumes; the manual
    -- /ec slash command is an explicit override path that bypasses this.
    if GetTime() < EC_compCache.userUntil then
        return
    end
    -- v2.9.0 / v2.10.0: post-CallCompanion server-confirm window. After
    -- we fire a CallCompanion the server can take 4-6 s under heavy combat
    -- to flip the companion's summoned flag to true; the next pet-tick
    -- (1 s cadence while EC_addonDismissed is true) would otherwise see
    -- scavengerOut=false still and fire a redundant CallCompanion. Five
    -- seconds covers the long-tail confirm; if the call was actually
    -- rejected the retry resumes after the wait. The print suppression
    -- below ensures even the retried CallCompanion stays silent if the
    -- announce already fired earlier in the cycle.
    if (GetTime() - EC_compCache.lastSummonAt) < 5 then
        return
    end
    -- Slot occupancy: if SOME other companion is in the slot, distinguish
    -- "user's manually-summoned critter" (respect it) from "our own
    -- leftover Goblin Merchant from the bag-full cycle that never got
    -- dismissed because the merchant window doesn't auto-clear it"
    -- (we should clear it to make room for the Scavenger).
    if anyPetOut and not goblinStillOut then
        return
    end
    if (GetTime() - EC_mountDismissTime) <= 10 then
        return
    end
    if not EC_compCache.addonDismissed then
        return
    end
    if not greedyIndex then
        return
    end
    if EC_IsPlayerBusy() then
        return
    end
    -- v2.11.0: optional combat-only summon. Defers stuck-recovery and
    -- post-merchant-restore CallCompanions until combat ends.
    if DB and DB.summonOnlyOutOfCombat and InCombatLockdown() then
        return
    end
    if goblinStillOut and DismissCompanion then
        -- Server-side; CallCompanion below toggles the slot atomically on
        -- most realms but a small minority queue both calls and only the
        -- last takes effect. Explicit dismiss is safer.
        DismissCompanion("CRITTER")
    end
    CallCompanion("CRITTER", greedyIndex)
    -- v2.9.0 / v2.10.0: surface the recovery in chat exactly once per
    -- dismiss-and-resummon cycle. Each dismiss site that wants the
    -- recovery announced sets EC_compCache.pendingAnnounce; the first
    -- successful CallCompanion in the cycle prints and clears the flag.
    -- Subsequent retries inside the same cycle (server slow to confirm
    -- the summon) call CallCompanion again but stay silent so the chat
    -- log doesn't fill with duplicate "resummoned" lines during heavy
    -- combat farming.
    if EC_compCache.pendingAnnounce then
        PrintNice(L["|cff00ff00Greedy Scavenger resummoned.|r"])
        EC_compCache.pendingAnnounce = false
    end
    -- Anchor the user-dismiss-vs-leash classification window for this summon
    -- too, so a fast portrait click that happens immediately after a recovery
    -- gets honoured the same way as one immediately after a manual /ec.
    EC_compCache.lastSummonAt = GetTime()
    if DB and DB.autoLootCycle then
        EC_compCache.lootCycleState = STATE.LOOTING
    end
end

-- 5 s-gated body. Pre-flight guards, state sync, stuck check, re-summon.
local function EC_PetCheckTick()
    if not DB or not DB.summonGreedy then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if IsMounted() then
        return
    end
    if EC_compCache.vendorRunning then
        return
    end

    EC_AutoLootStateSync()
    -- Bag-full detection lives in BAG_UPDATE (EC_HandleBagFullForCycle).

    if EC_compCache.lootCycleState == STATE.WAITING_MERCHANT or EC_compCache.lootCycleState == STATE.SELLING then
        return
    end

    local num = GetNumCompanions("CRITTER")
    if not num or num <= 0 then
        return
    end
    local greedyIndex, scavengerOut, anyPetOut, goblinStillOut = nil, false, false, false
    for i = 1, num do
        local _, creatureName, spellID, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if isSummoned then
            anyPetOut = true
            -- Track whether the in-slot pet is OUR leftover goblin from a
            -- recent bag-full cycle. The goblin doesn't auto-dismiss when
            -- the merchant window closes; if we treat it as "user's other
            -- companion" the resummon path will respect it forever and
            -- never bring the Scavenger back. Distinguished from a
            -- genuine third-party companion (bank mule, mailbox) which
            -- the addon never summons.
            if creatureName == TARGET_NAME or spellID == GOBLIN_MERCHANT_SPELL_ID then
                goblinStillOut = true
            end
        end
        if creatureName == PET_NAME then
            greedyIndex = i
            if isSummoned then
                scavengerOut = true
            end
        end
    end

    -- Reset the movement accumulator on every out<->in transition so each
    -- new summon (and each fresh dismiss) starts the stuck-counter cleanly.
    -- Also confirm the dismiss-and-resummon retry loop in EC_TryResummonScavenger
    -- here: a false->true transition while EC_addonDismissed is still true
    -- means our last CallCompanion landed, so we can clear the flag and stop
    -- retrying. (If the player summoned manually via /ec, SummonGreedyScavenger
    -- has already cleared the flag itself.)
    if EC_compCache.lastScavengerOut ~= scavengerOut then
        EC_scavMovementAccum = 0
        -- Drop any prior loot timestamps so a fresh out<->in transition starts
        -- the loot-silence counter cleanly (otherwise stale pre-transition
        -- loots could trigger an immediate re-fire after a benign respawn).
        EC_recentLootTimes = {}
        -- v2.9.0: classify true -> false transitions as a possible manual
        -- portrait dismiss. The `not EC_addonDismissed` guard is the
        -- definitive signal: every addon-driven dismiss path
        -- (DismissGreedyScavenger, EC_HandleBagFullForCycle, the auto-loot
        -- cycle's mid-cycle dismiss before summoning the Goblin Merchant)
        -- sets EC_addonDismissed = true, so any transition that reaches
        -- here with the flag still false was not us. If the timing also
        -- lands inside EC_compCache.USER_WINDOW_S of our last summon we
        -- mark a 30 s grace via EC_compCache.userUntil and EC_TryResummonScavenger
        -- honours it. Range-leash transitions take longer than 5 s to
        -- surface, so they fall outside the window and the existing
        -- recovery path runs unchanged.
        if EC_compCache.lastScavengerOut and not scavengerOut and not EC_compCache.addonDismissed then
            if (GetTime() - EC_compCache.lastSummonAt) < EC_compCache.USER_WINDOW_S then
                EC_compCache.userUntil = GetTime() + EC_compCache.USER_GRACE_S
            end
        end
        if scavengerOut and EC_compCache.addonDismissed then
            EC_compCache.addonDismissed = false
            -- v2.10.0: cycle ended cleanly - the server has confirmed the
            -- summon. Drop any leftover pendingAnnounce so the next
            -- dismiss-and-resummon cycle starts from a known-clean state.
            EC_compCache.pendingAnnounce = false
        end
        -- v2.8.0: refresh the loot-silence baseline on every fresh out
        -- transition (false->true). Pet just appeared; even if the speech
        -- detection misses something, the silence clock should not start
        -- counting from the moment of summon -- the pet hasn't had time
        -- to vacuum anything yet.
        if scavengerOut then
            EC_compCache.lastScavSpokeAt = GetTime()
        end
    end
    EC_compCache.lastScavengerOut = scavengerOut

    if EC_HandleScavengerOut(scavengerOut) then
        return
    end
    EC_TryResummonScavenger(greedyIndex, anyPetOut, goblinStillOut)
end

EC_petCheckFrame:SetScript("OnUpdate", function(_, elapsed)
    -- Accumulate player movement time while the Scavenger is flagged as out.
    -- EC_HandleScavengerOut reads this on the 5 s tick to detect "stuck" cases.
    if EC_compCache.lastScavengerOut and GetUnitSpeed and GetUnitSpeed("player") > 0 then
        EC_scavMovementAccum = EC_scavMovementAccum + elapsed
    end

    if EC_TickGoblinSummon(elapsed) then
        return
    end
    if EC_TickGoblinTarget(elapsed) then
        return
    end
    EC_TickMerchantReminder(elapsed)

    EC_petCheckElapsed = EC_petCheckElapsed + elapsed
    -- v2.6.2: when actively trying to resummon (EC_addonDismissed = true),
    -- sample at 1 s instead of 5 s so we catch cast-clear windows much
    -- faster during heavy combat. Falls back to the 5 s baseline once the
    -- pet is back and we're just polling for the next stuck/dismiss event.
    local interval = EC_compCache.addonDismissed and 1 or EC_PET_CHECK_INTERVAL
    if EC_petCheckElapsed < interval then
        return
    end
    EC_petCheckElapsed = 0
    EC_PetCheckTick()
    -- v2.44.5: bag-full watchdog runs on the same 1-5 s cadence as the
    -- pet tick. Detects a stuck swap cycle and force-resets so the player
    -- isn't permanently grounded with full bags + a scavenger that won't
    -- swap to the goblin merchant. Definition is near EC_HandleBagFullForCycle.
    EC_BagFullWatchdog()
end)

-- pendingDelete state was promoted from a file-scope local to
-- EC_compCache.pendingDelete (initialised in EbonClearance_Core.lua's
-- table literal) for the same Stage 5 reason as vendorRunning above.
-- The HookDeletePopupOnce body that consumes pendingDelete moved to
-- EbonClearance_Vendor.lua (Stage 5 of the file split, exposed as
-- NS.HookDeletePopupOnce). The deletePopupHooked install-once gate
-- moved with it.

-- v2.9.0: bag snapshot for manual-sell attribution. Run at MERCHANT_SHOW so
-- the post-call hook can look up what was in (bag, slot) before the player
-- right-clicked it. By the time hooksecurefunc fires the slot is empty, so
-- a synchronous read inside the hook can't see what was sold. All three
-- helpers hang off EC_manualSell to keep main-chunk local count down (Lua
-- 5.1 caps that at 200).
-- v2.37.0: add a sell's copper to the current zone's lifetime total
-- (or "Unknown" when the zone text isn't ready, e.g. mid-load). Shared by
-- the manual UseContainerItem hook and the worker-cycle FinishRun so the
-- Stats panel's "Top Zones" rollup matches the wallet totals.
function EC_compCache.attributeCopperToZone(copper)
    local zone = GetRealZoneText and GetRealZoneText() or nil
    if not zone or zone == "" then
        zone = "Unknown"
    end
    -- v2.59.5 (Serv report): drop city sales. Vendoring mailboxed items
    -- in Dalaran / Stormwind / etc. is not farming and would otherwise
    -- pollute the Top Zones leaderboard. Wallet totalCopper is bumped
    -- separately by the caller, so wallet views stay accurate.
    if EC_CITY_ZONES[zone] then
        return
    end
    -- v2.38.1: helper writes to DB AND ADB.accountStats for the
    -- account-view aggregate.
    EC_BumpStatBucket("copperByZone", zone, copper)
end

function EC_manualSell.snapshotBags()
    wipe(EC_manualSell.snapshot)
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, count = GetContainerItemInfo(bag, slot)
                EC_manualSell.snapshot[bag * 1000 + slot] = {
                    link = link,
                    count = count or 1,
                    itemID = GetContainerItemID(bag, slot),
                }
            end
        end
    end
end

function EC_manualSell.refreshSlot(bag, slot)
    if not bag or not slot then
        return
    end
    local key = bag * 1000 + slot
    local link = GetContainerItemLink(bag, slot)
    if link then
        local _, count = GetContainerItemInfo(bag, slot)
        EC_manualSell.snapshot[key] = {
            link = link,
            count = count or 1,
            itemID = GetContainerItemID(bag, slot),
        }
    else
        EC_manualSell.snapshot[key] = nil
    end
end

-- Hook UseContainerItem ONCE at addon load. hooksecurefunc preserves the
-- original (we cannot replace it: UseContainerItem is in the secure-dispatch
-- path for items that trigger spells/casts, and Blizzard's secure system
-- silently rejects calls to a non-Blizzard implementation). The hook only
-- attributes a sell when (a) we did NOT do it ourselves (EC_manualSell.inSelfSell is
-- false) and (b) the merchant frame is open and (c) the snapshot has an
-- entry for that slot - i.e. the item was present at MERCHANT_SHOW or after
-- the last refresh. Stat fields match what DoNextAction bumps for the
-- worker-driven path so lifetime/session totals are uniform regardless of
-- which path actually completed the sale.
function EC_manualSell.installHookOnce()
    if EC_manualSell.hookInstalled then
        return
    end
    EC_manualSell.hookInstalled = true
    hooksecurefunc("UseContainerItem", function(bag, slot)
        if EC_manualSell.inSelfSell then
            return
        end
        if not (MerchantFrame and MerchantFrame:IsShown()) then
            return
        end
        if not bag or not slot then
            return
        end
        local snap = EC_manualSell.snapshot[bag * 1000 + slot]
        if snap and snap.link then
            local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(snap.link)
            if sellPrice and sellPrice > 0 then
                local copper = sellPrice * (snap.count or 1)
                if DB then
                    -- v2.38.1: helpers write to DB + ADB.accountStats.
                    EC_BumpStat("totalCopper", copper)
                    EC_BumpStat("totalItemsSold", 1)
                    if snap.itemID then
                        EC_BumpStatBucket("soldItemCounts", snap.itemID, 1)
                    end
                    if quality then
                        EC_BumpStatBucket("soldItemsByQuality", quality, 1)
                        EC_BumpStatBucket("soldCopperByQuality", quality, copper)
                    end
                    -- v2.37.0: attribute the sell to the current zone.
                    EC_compCache.attributeCopperToZone(copper)
                end
                EC_session.copper = EC_session.copper + copper
                EC_session.sold = EC_session.sold + 1
                -- v2.51.0: recent-sold ring buffer for /ec bugreport.
                EC_LogRecentSold(snap.itemID, snap.count or 1, "manual", copper)
            end
        end
        -- Refresh the snapshot for this slot after the sell completes. The
        -- 0.1 s delay gives the bag a tick to update before we re-read
        -- (hooksecurefunc fires synchronously inside the protected call,
        -- so the slot may still report the just-sold item if we read now).
        EC_Delay(0.1, function()
            EC_manualSell.refreshSlot(bag, slot)
        end)
    end)
end

-- ===========================================================================
-- v2.73.0 external-action attribution (competitive review Tier A,
-- owner-promoted 2026-07-31).
-- ---------------------------------------------------------------------------
-- Sold History only recorded EbonClearance's own actions, so a manual
-- drag-delete (or another addon's cursor delete) left no trail and the
-- "your addon deleted my item" report class could not be answered from
-- inside the game. Two hooksecurefunc hooks (never a global replacement
-- - house convention) attribute cursor deletes EC did not perform:
--
--   * PickupContainerItem remembers what landed on the cursor. The hook
--     fires after the pickup; GetCursorInfo is the truth for WHAT is
--     held, the (still-locked) slot supplies the count.
--   * DeleteCursorItem logs the remembered item as source="external"
--     UNLESS the delete was EC's own: executeBagSlotDelete arms
--     EC_compCache.pendingDelete (bag/slot/itemID + an `at` stamp)
--     immediately before its DeleteCursorItem call, so the hook
--     subtracts self by matching all three fields within a 1 s window
--     (the window guards against a stale pendingDelete from an earlier
--     popup-less delete matching a later manual delete of the same
--     item in the same slot).
--
-- External rows carry a neutral reason, are EXCLUDED from every stat
-- counter (these are not EC actions - the row exists to prove that),
-- and surface in the Sold History window + /ec bugreport's Recent
-- Deleted section via the existing ring. State + installer live on
-- EC_compCache (the Events main chunk is at the 200-locals cap).
function EC_compCache.installExternalActionHooksOnce()
    if EC_compCache.externalActionHooksInstalled then
        return
    end
    EC_compCache.externalActionHooksInstalled = true
    hooksecurefunc("PickupContainerItem", function(bag, slot)
        local kind, cursorItemID = GetCursorInfo()
        if kind == "item" and cursorItemID then
            local count
            if bag and slot and GetContainerItemID(bag, slot) == cursorItemID then
                local _, slotCount = GetContainerItemInfo(bag, slot)
                count = slotCount
            end
            EC_compCache.lastCursorPickup = { itemID = cursorItemID, count = count or 1, bag = bag, slot = slot }
        else
            EC_compCache.lastCursorPickup = nil
        end
    end)
    hooksecurefunc("DeleteCursorItem", function()
        local cp = EC_compCache.lastCursorPickup
        EC_compCache.lastCursorPickup = nil
        if not cp then
            return
        end
        local pd = EC_compCache.pendingDelete
        local ours = pd
            and pd.itemID == cp.itemID
            and pd.bag == cp.bag
            and pd.slot == cp.slot
            and (GetTime() - (pd.at or 0)) < 1
        if ours then
            return -- executeBagSlotDelete already logged + counted it
        end
        -- v2.75.0 (fresh-audit 2026-08-03): DeleteCursorItem also fires when the
        -- Blizzard confirmation popup is RAISED for a rare/epic/quest item, not
        -- only when the delete completes - which is exactly why EC's own
        -- good-item deletes need HookDeletePopupOnce. Logging here recorded a
        -- false "Deleted outside EbonClearance" row that stayed forever if the
        -- player then clicked Cancel. Defer: remember the candidate and its
        -- current in-bag count, and let the settled bag flush confirm the item
        -- actually left the bags before writing the row. GetItemCount excludes
        -- the on-cursor item, so a completed delete leaves the count unchanged
        -- while a cancel returns the item and raises it.
        EC_compCache.pendingExternalDelete = {
            itemID = cp.itemID,
            count = cp.count,
            bagCount = (GetItemCount and GetItemCount(cp.itemID)) or 0,
            at = GetTime(),
        }
    end)
end

-- v2.75.0 (fresh-audit fix): confirm-or-drop a deferred external-delete
-- candidate. Called from the settled bag flush. While the delete popup is still
-- open the item sits on the cursor - wait. Once the cursor clears, an unchanged
-- in-bag count means the item was really destroyed (log it); a raised count
-- means the player cancelled and it returned to the bags (drop it). Expires
-- after 30 s so a popup left open forever cannot leak a stale candidate.
function EC_compCache.confirmPendingExternalDelete()
    local pe = EC_compCache.pendingExternalDelete
    if not pe then
        return
    end
    if GetTime() - (pe.at or 0) > 30 then
        EC_compCache.pendingExternalDelete = nil
        return
    end
    if GetCursorInfo and GetCursorInfo() == "item" then
        return -- popup still open / item still held; re-check next settle
    end
    EC_compCache.pendingExternalDelete = nil
    local nowCount = (GetItemCount and GetItemCount(pe.itemID)) or 0
    if nowCount <= (pe.bagCount or 0) then
        EC_LogRecentDeleted(pe.itemID, pe.count, "external", L["Deleted outside EbonClearance - by you or another addon"])
    end
end

local EC_IsMerchantAllowed -- forward declaration for FinishRun
-- `running` is forward-declared at the top of the file.
local queue = {}
local queueIndex = 1
local goldThisVendoring = 0
local EC_batchTotalSold = 0
local EC_batchTotalGold = 0

-- v2.46.4 vendor-refusal blacklist. Reported by Broyo: an Epic item
-- the vendor refuses to buy (server-side BoP-on-use, quest-adjacent,
-- stale GetItemInfo cache) wedged the sell cycle. UseContainerItem
-- returned silently, the slot stayed full, BuildQueue's fresh bag
-- walk re-queued the item, and the loop spammed "Sold X items so
-- far" forever. Keyed by (bag * 100 + slot) -> itemID so the entry
-- only blocks the exact item that was refused; a different item
-- landing in the same slot still gets a fresh try. Wiped on
-- StartRun / MERCHANT_CLOSED so a new merchant visit retries.
-- EC-TRAP: do not drop the itemID equality check - a key-only
-- presence test would block organic slot-moves and freeze
-- legitimate sells.
local EC_vendorRefusedThisRun = {}
local function EC_refusalKey(bag, slot) return bag * 100 + slot end

local worker = CreateFrame("Frame")
worker:Hide()

-- v2.13.0 quest-item safety net. Returns true iff GetItemInfo classifies
-- the item as itemClass "Quest". Used by EC_IsSellable and BuildQueue's
-- delete branch to refuse auto-vendor / auto-delete on quest items even
-- when they're explicitly on the whitelist or delete list. Catches the
-- failure mode where a user added an item to a list months ago and then
-- later picked it up for a quest. Manual paths (Alt+Right-Click → Sell
-- Now / Delete Now) are NOT gated by this - those represent explicit
-- user intent. GetItemInfo's 6th return is the top-level item class
-- ("Armor", "Weapon", "Quest", "Consumable", etc.); "Quest" is the
-- enUS string and is what the localised client also returns here in
-- 3.3.5a (it's a category key, not display text).
function EC_compCache.isQuestItem(itemID)
    if not itemID then
        return false
    end
    local _, _, _, _, _, itemType = GetItemInfo(itemID)
    return itemType == "Quest"
end

-- Shared sell predicate. Used by BuildQueue to build the vendor queue and by
-- EC_PreviewSellable to drive the minimap mouse-over preview. Returns:
--   sellable (bool), link, itemID, sellPrice, itemCount, quality.
-- `junkOnly` restricts matches to quality-0 items (used when the current
-- merchant mode disallows the whitelist/quality threshold).
--
-- INVARIANT: Grey items (quality == 0) with a positive sell price ALWAYS
-- match via isJunk, independent of DB.whitelist, DB.whitelistQualityEnabled,
-- or DB.whitelistMinQuality. The quality threshold only gates non-grey
-- items. Do not "simplify" the three independent passes (isJunk /
-- qualityPass / whitelistPass) into one combined check -- you will silently
-- break the grey-always-sold guarantee that users and docs rely on.
-- Blacklist and IsEquippedItem are the only things that can veto a sale.
-- EC-TRAP: do NOT combine isJunk / qualityPass / whitelistPass into
-- "one cleaner check" - that breaks the grey-always-sold guarantee (see
-- ADDON_GUIDE "Grey items are always sold").
-- (Historical note: this trap once also forbade unifying EC_AnnotateTooltip
-- with this logic. That was RETIRED in v2.71.2 - the tooltip now renders from
-- the shared decision core, so the DECISION is unified; only the label
-- formatting is still per-surface. See docs/CODE_REVIEW.md item 6.)
-- v2.71.0 (decision-classifier Stage 1): EC_IsSellable is now a thin
-- delegate over the pure decision core in EbonClearance_Decision.lua.
-- The 500-line decision body moved there VERBATIM (see the spec at
-- docs/specs/2026-07-29-decision-classifier-design.md); this wrapper
-- preserves the historical return contract
-- (sellable, link, itemID, sellPrice, itemCount, quality) and the
-- lastSellSignal scratch that BuildQueue reads. The trace and tooltip
-- mirrors convert in Stages 2-3; until then their EC-TRAP parity
-- contracts hold against the core's behaviour (identical by
-- construction + pinned at runtime by tests/test_decision.lua).
local function EC_IsSellable(bag, slot, junkOnly)
    local ctx = NS.Decision and NS.Decision.buildCtx(bag, slot, junkOnly)
    if not ctx then
        return false
    end
    local verdict, token, fields = NS.Decision.sell(ctx)
    if verdict ~= "sell" then
        return false
    end
    EC_compCache.lastSellSignal = (fields and fields.signal) or token
    return true, ctx.link, ctx.itemID, ctx.sellPrice, ctx.count, ctx.quality
end
NS.IsSellable = EC_IsSellable

-- Plain-English "why sold" line for the session decision log, built from the
-- signal EC_IsSellable just recorded. The history window has room to spell it
-- out fully (unlike the tooltip), and because the signal comes straight from
-- EC_IsSellable the explanation can't drift from the real sell logic.
function EC_compCache.sellReasonForSignal(signal, quality, rule)
    -- v2.68.0: quality NAMES, not tooltip colour words. This expression
    -- used to read White / Green / Blue / Epic - three colours and one
    -- quality name, so the same window could print "white item" and
    -- "Epic item" a line apart. Matches the Merchant panel wording.
    local rarity = (quality == 1 and L["Common"])
        or (quality == 2 and L["Uncommon"])
        or (quality == 3 and L["Rare"])
        or (quality == 4 and L["Epic"])
        or "?"
    if signal == "whitelist_char" then
        return L["On your Sell List - you marked this item to always be sold."]
    elseif signal == "whitelist_account" then
        return L["On your account-wide Sell List (shared across all your characters)."]
    elseif signal == "recipe" then
        return L["A profession recipe this character has already learned - Sell Known Recipes vendored the duplicate."]
    elseif signal == "knownproc" then
        return L["A chance-on-hit item whose proc you've already extracted - sold because 'sell known chance-on-hit procs' is on."]
    elseif signal == "affixrank" then
        return L["Its Project Ebonhold affix rank is below your 'sell affixes below rank' threshold."]
    elseif signal == "autodupe" then
        return L["You already have this affix - 'sell affixes you already have' vendored the duplicate."]
    elseif signal == "junk" then
        return L["Grey (poor) quality with a vendor price - grey junk is always auto-sold."]
    end
    -- Quality-rule case: spell out the item-level decision + any bind filter.
    local bindNote = ""
    if rule and rule.bindFilter == "boe" then
        bindNote = L[" (BoE only)"]
    elseif rule and rule.bindFilter == "bop" then
        bindNote = L[" (BoP only)"]
    end
    if rule and rule.useEquippedILvl then
        return string.format(
            L["Matched your %s auto-sell rule: its item level was below what you have equipped in that slot%s."],
            rarity, bindNote
        )
    elseif rule and (rule.maxILvl or 0) > 0 then
        return string.format(
            L["Matched your %s auto-sell rule: its item level was at or below your cap of %d%s."],
            rarity, rule.maxILvl, bindNote
        )
    end
    return string.format(L["Matched your %s auto-sell rule (it sells all items of that rarity)%s."], rarity, bindNote)
end

-- v2.47.0: does affix protection RELEASE this affix - i.e., is EC willing to
-- get rid of it rather than keep it? True when ANY of:
--   * the player Allow-Sell'd this exact affix (ADB.allowedAffixes), OR
--   * it's an owned exact-rank dupe AND a dupe-disposal toggle is on
--     (affixAllowExactDupes for selling, or autoMarkAffixDupes for deleting), OR
--   * its rank is below the "Sell affixes below rank" floor (affixMinSellRank).
-- This is the release side of EC_IsSellable's affix-protection block, shared by
-- deleteListSlotEligible (the per-instance delete gate) and runAutoMarkAffixDupes
-- (which marks the released-but-UNSELLABLE ones for deletion). Keep in lockstep
-- with EC_IsSellable's affix block.
function EC_compCache.affixDisposable(affix)
    local DB = NS.DB
    if not (affix and DB) then
        return false
    end
    local affixKey = affix.description
        and EC_compCache.normaliseAffixDesc
        and EC_compCache.normaliseAffixDesc(affix.description)
    local ADB = NS.ADB
    if affixKey and ADB and ADB.allowedAffixes and ADB.allowedAffixes[affixKey] then
        return true
    end
    if (DB.affixAllowExactDupes or DB.autoMarkAffixDupes) and EC_compCache.playerOwnsAffix(affix) then
        return true
    end
    if DB.affixMinSellRank and DB.affixMinSellRank > 0 and affix.rank and affix.rank < DB.affixMinSellRank then
        return true
    end
    return false
end

-- v2.42.0: shared Delete-List eligibility predicate. Returns (itemID, count,
-- quality) when the bag slot holds a Delete-List item eligible for destruction,
-- else nil. Used by BuildQueue's delete branch, DoNextAction's drain-time
-- re-validation, and the auto-delete-on-pickup scan so vendor-delete and
-- auto-delete apply identical policy with zero drift.
-- v2.71.3 (classifier Stage 4): now a thin delegate - the eligibility policy
-- (the v2.50.2 Keep-signal / equipped rescues and the v2.47.0 affix gate)
-- lives in NS.Decision.deleteEligible, with its rationale + EC-TRAPs.
function EC_compCache.deleteListSlotEligible(bag, slot)
    local DB = NS.DB
    if not (DB and DB.deleteList) then
        return nil
    end
    -- Cheap membership pre-gate BEFORE building a decision ctx: this
    -- predicate runs per slot inside the BAG_UPDATE scans and BuildQueue,
    -- and unlisted slots (the overwhelming majority) must stay at one
    -- item-ID read + one table lookup. Only listed slots pay for the
    -- snapshot.
    local id = GetContainerItemID(bag, slot)
    if not (id and IsInSet(DB.deleteList, id)) then
        return nil
    end
    -- v2.71.3 (classifier Stage 4): the eligibility policy lives in the
    -- decision core. The v2.50.2 rescue vetoes (Keep List / account Sell
    -- List / equipped - the Stickybackpack shirt-loss fix) and the
    -- v2.47.0 affixDisposable gate moved there WITH their EC-TRAPs.
    local ctx = NS.Decision and NS.Decision.buildCtx(bag, slot, false)
    if not ctx then
        return nil
    end
    if not NS.Decision.deleteEligible(ctx) then
        return nil
    end
    return ctx.itemID, ctx.count, ctx.quality
end

-- v2.42.0: shared destructive delete of one bag slot. Picks the item up,
-- queues pendingDelete (so HookDeletePopupOnce auto-confirms the DELETE_*
-- popup), deletes it, and bumps the deletion stats - identical accounting for
-- the vendor path and the auto-delete path. `announce` true prints one chat
-- line (auto-delete); the vendor path passes false (it has its own summary).
-- v2.60.0: per-rarity chat-announce gate. Master toggle
-- (announceAutoDelete) OFF silences everything; ON lets the per-quality
-- sub-filter (announceAutoDeleteQualities) decide. Unknown quality
-- (nil) errs on the side of announcing so we never silently drop an
-- event the user might care about. Consumed by executeBagSlotDelete +
-- runAutoMarkResilience + runAutoMarkAffixDupes.
function EC_compCache.shouldAnnounceAutoDelete(quality)
    if not DB or DB.announceAutoDelete == false then
        return false
    end
    if not DB.announceAutoDeleteQualities then
        return true
    end
    if quality == nil then
        return true
    end
    return DB.announceAutoDeleteQualities[quality] == true
end

-- Returns true if the delete was issued.
function EC_compCache.executeBagSlotDelete(bag, slot, itemID, count, quality, announce)
    ClearCursor()
    PickupContainerItem(bag, slot)
    if GetCursorInfo() ~= "item" then
        ClearCursor()
        EC_compCache.pendingDelete = nil
        return false
    end
    -- The `at` stamp lets the v2.73.0 external-delete hook subtract this
    -- self-delete even when pendingDelete lingers (popup-less deletes
    -- never consume it).
    EC_compCache.pendingDelete = { bag = bag, slot = slot, itemID = itemID, at = GetTime() }
    DeleteCursorItem()
    ClearCursor()
    local delCount = count or 1
    EC_BumpStat("totalItemsDeleted", delCount)
    EC_session.deleted = EC_session.deleted + delCount
    if itemID then
        EC_BumpStatBucket("deletedItemCounts", itemID, delCount)
    end
    if quality then
        EC_BumpStatBucket("deletedItemsByQuality", quality, delCount)
    end
    -- v2.51.0: recent-deleted ring buffer for /ec bugreport. `announce`
    -- true means the auto-delete path called us (chat announcement
    -- follows); false means the vendor cycle's delete queue action
    -- executed. Source tag preserves that distinction so a report can
    -- separate "worker cleanup" from "auto-delete-on-pickup fired".
    EC_LogRecentDeleted(itemID, delCount, announce and "auto" or "vendor")
    if announce and EC_compCache.shouldAnnounceAutoDelete(quality) then
        local link = select(2, GetItemInfo(itemID)) or ("item:" .. tostring(itemID))
        PrintNicef(L["|cffff4444Auto-deleted|r %s."], link)
    end
    return true
end

-- v2.42.0: auto-delete-on-pickup scan. Runs from the BAG_UPDATE debounce only.
-- Deletes ONE eligible Delete-List item per cycle; the deletion fires another
-- BAG_UPDATE which re-fires the debounce for the next one, self-terminating
-- when none remain (ineligible items are skipped, so no loop).
-- EC-TRAP: one-per-cycle by design (no batch loop). Each delete fires a
-- BAG_UPDATE that re-fires the debounce for the next item; the scan waits on a
-- visible DELETE_* popup so confirmation-required items resolve one at a time.
-- Do NOT "optimise" into a batch delete, and do NOT gate on pendingDelete
-- instead of the popup (low-rarity items delete with no popup and never clear
-- pendingDelete, which would wedge the cascade after the first item).
-- EC-TRAP: deliberately NOT gated on InCombatLockdown - DeleteCursorItem is
-- not combat-protected on 3.3.5a and farming happens in combat, which is the
-- whole point of the feature. Do NOT add a combat guard.
function EC_compCache.runAutoDeleteOnPickup()
    local DB = NS.DB
    -- v2.42.1: master Enable toggle must veto the sweep, same as the
    -- vendor cycle / scavenger / auto-loot paths do. Without this gate,
    -- a player who right-clicks the minimap to "turn the addon off"
    -- can still trigger destructive deletes via Alt+Right-Click ->
    -- Mark for delete followed by a /reload (real report from
    -- Sanavesa on v2.42.0). The master gate is the user's only kill
    -- switch for the entire addon - it MUST veto every destructive
    -- path. Routed through the existing helper for consistency with
    -- the vendor cycle (EC_IsAddonEnabledForChar handles both
    -- DB.enabled and the per-character whitelist).
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if not (DB and DB.enableDeletion and DB.autoDeleteOnPickup) then
        return
    end
    -- Stamped after the feature gates (not at function entry) so the
    -- bugreport's last-ran line for this scan means it actually ran, and a
    -- flush with the feature off pays no stamp.
    EC_StampEvent("autoDeleteScan")
    if EC_compCache.vendorRunning then
        return
    end
    -- Wait if a delete-confirmation popup from a prior delete is still on
    -- screen (HookDeletePopupOnce confirms it; the resulting BAG_UPDATE
    -- re-fires this scan for the next item). Gate on the VISIBLE popup, NOT
    -- on pendingDelete: a low-rarity item deletes with no popup and never
    -- clears pendingDelete, so gating on pendingDelete would wedge the
    -- cascade after the first item (only one of several would be deleted).
    local popup = StaticPopup1
    if popup and popup:IsShown() and popup.which and popup.which:find("^DELETE_") then
        return
    end
    if GetCursorInfo() then
        return
    end
    -- v2.59.0: iterate the shared flush snapshot; only slots whose
    -- snapshotted itemID is on the Delete List reach the eligibility gate,
    -- so unlisted slots cost one table lookup each. deleteListSlotEligible
    -- re-reads the live slot itself, so a moved/changed slot returns nil.
    local snap = EC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        local e = snap.entries[i]
        if IsInSet(DB.deleteList, e.itemID) then
            local id, count, quality = EC_compCache.deleteListSlotEligible(e.bag, e.slot)
            if id then
                EC_compCache.executeBagSlotDelete(e.bag, e.slot, id, count, quality, true)
                return
            end
        end
    end
end

-- v2.49.2: auto-delete grey items on loot. Runs from the BAG_UPDATE
-- debounce alongside the auto-mark scans. Opt-in via
-- DB.autoDeleteGreyOnLoot, gated on DB.enableDeletion (master switch)
-- + the per-character Enable, a merchant NOT being open (a vendor
-- round-trip yields copper the delete throws away), item quality 0,
-- positive sellPrice (avoids trashing quest keys / 0-value
-- curiosities), not a quest item, not equipped, and not on any Keep
-- List variant / auto-blacklist / the manual Delete List. Deletes via
-- the shared executeBagSlotDelete path (same plumbing + stats + popup
-- serialisation as the auto-delete-on-pickup scan). One delete per
-- BAG_UPDATE burst; the resulting BAG_UPDATE re-fires the debounce for
-- the next grey, self-terminating when none remain.
-- EC-TRAP: reuse EC_compCache.executeBagSlotDelete - do NOT invent a
-- parallel PickupContainerItem + DeleteCursorItem path. The shared
-- helper owns pendingDelete / HookDeletePopupOnce serialisation; a
-- second raw delete path would race the popup mutex.
function EC_compCache.runAutoDeleteGrey()
    local DB = NS.DB
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if not (DB and DB.enableDeletion and DB.autoDeleteGreyOnLoot) then
        return
    end
    if EC_compCache.vendorRunning then
        return
    end
    -- Vendor round-trip is imminent and yields copper; a grey delete
    -- throws that away. Skip while a merchant is open; the next
    -- BAG_UPDATE after MERCHANT_CLOSED re-fires this scan.
    if MerchantFrame and MerchantFrame:IsShown() then
        return
    end
    -- Wait on a visible delete popup / held cursor, same discipline as
    -- the auto-delete-on-pickup scan (gate on the VISIBLE popup, not
    -- pendingDelete - low-rarity greys delete with no popup).
    local popup = StaticPopup1
    if popup and popup:IsShown() and popup.which and popup.which:find("^DELETE_") then
        return
    end
    if GetCursorInfo() then
        return
    end
    local keepList = DB.blacklist
    local accountKeep = NS.ADB and NS.ADB.whitelist
    local blacklistAuto = DB.blacklistAuto
    local deleteList = DB.deleteList
    -- v2.59.0: iterate the shared flush snapshot. The snapshot quality
    -- (GetContainerItemInfo's 4th return) pre-gates the GetItemInfo call:
    -- entries KNOWN to be quality 1+ are skipped outright; nil / -1
    -- (uncached) entries fall through to the authoritative GetItemInfo
    -- check below, never to a skip. This scan runs AFTER the pickup-delete
    -- scan (which can synchronously destroy one item), so the live slot is
    -- re-verified against the snapshotted itemID before acting.
    local snap = EC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        local e = snap.entries[i]
        local id = e.itemID
        if (e.quality == nil or e.quality < 1) and GetContainerItemID(e.bag, e.slot) == id then
            local _, _, quality, _, _, itemType, _, _, _, _, sellPrice = GetItemInfo(id)
            if quality == 0
                and sellPrice
                and sellPrice > 0
                and itemType ~= "Quest"
                and not IsEquippedItem(id)
                and not (keepList and keepList[id])
                and not (accountKeep and accountKeep[id])
                and not (blacklistAuto and blacklistAuto[id])
                and not (deleteList and deleteList[id])
            then
                local _, count, locked = GetContainerItemInfo(e.bag, e.slot)
                if not locked and count and count > 0 then
                    EC_compCache.executeBagSlotDelete(e.bag, e.slot, id, count, quality, true)
                    return -- one delete per BAG_UPDATE burst
                end
            end
        end
    end
end

-- v2.50.3: session-scoped auto-mark event log. Ring buffer of the last N
-- items runAutoMarkAffixDupes or runAutoMarkResilience wrote to
-- DB.deleteList. Consumed by /ec bugreport so a report tells us WHEN and
-- WHY EC last auto-marked something, without asking the user's chat log
-- to survive as evidence. Session-local (not persisted); wiped on
-- /reload. Ring shifts oldest out on overflow.
local EC_AUTOMARK_LOG_MAX = 15
local EC_autoMarkLog = {}

local function EC_LogAutoMark(itemID, reason)
    if not itemID then
        return
    end
    if #EC_autoMarkLog >= EC_AUTOMARK_LOG_MAX then
        table.remove(EC_autoMarkLog, 1)
    end
    local _, link = GetItemInfo(itemID)
    EC_autoMarkLog[#EC_autoMarkLog + 1] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        reason = reason or "?",
        loggedAt = date("%H:%M:%S"),
    }
end
NS.LogAutoMark = EC_LogAutoMark
NS.autoMarkLog = EC_autoMarkLog
NS.autoMarkLogMax = EC_AUTOMARK_LOG_MAX

-- v2.51.0: session-scoped ring buffers for what EC has SOLD and DELETED
-- this session. The lifetime + session counters in DB / ADB.accountStats
-- tell "how much" but say nothing about "which items and when", so when
-- a user reports "it sold something I didn't want" there's no evidence
-- trail. These ring buffers capture the last N of each so /ec bugreport
-- surfaces them.
--
-- path/source tags:
--   * recentSold.path   = "manual" (user clicked at vendor, hooksecurefunc
--                                    fired) or "worker" (EC vendor cycle
--                                    UseContainerItem)
--   * recentDeleted.source = "auto" (auto-delete-on-pickup) or "vendor"
--                                    (vendor-cycle delete queue action)
--
-- v2.57.0: these are the FULL session logs behind the Sold History window,
-- not just a "recent" snapshot. Cap is high (5000 each) so a whole farming
-- session is captured; on overflow the oldest shift out and a trim counter
-- records how many, so the window can tell the player "N earlier entries
-- trimmed" rather than silently dropping them. /ec bugreport still shows only
-- the last EC_BUGREPORT_RECENT_MAX of each (a tail slice) so reports stay
-- short. Session-local, wiped on /reload; never persisted.
local EC_RECENT_SOLD_LOG_MAX = 5000
local EC_RECENT_DELETED_LOG_MAX = 5000
local EC_BUGREPORT_RECENT_MAX = 20
local EC_recentSoldLog = {}
local EC_recentDeletedLog = {}
local EC_soldLogTrimmed = 0
local EC_deletedLogTrimmed = 0
-- v2.68.1: per-log write counters driving a TRUE ring. At the cap the old
-- code did table.remove(t, 1) per event - an O(5000) front-shift on the
-- vendor path during exactly the marathon sessions that fill the log
-- (Turbo mode sells up to 80 items per run). The write slot is now
-- ((writes - 1) % MAX) + 1: below the cap that is a plain append, at the
-- cap it overwrites the oldest in place. The array order becomes ROTATED
-- at the cap - readers must order by the per-entry `seq`, never by array
-- index (the Sold History window always did; /ec bugreport was converted
-- alongside this change). On EC_compCache, not file-scope locals: the main
-- chunk sits at Lua 5.1's 200-locals cap.
EC_compCache.soldLogWrites = 0
EC_compCache.deletedLogWrites = 0
-- Monotonic insertion sequence stamped on every entry so the Sold History
-- window can merge the two logs into an exact newest-first order (loggedAt is
-- only 1 s granular and would tie). Session-local.
local EC_historySeq = 0

-- `reason` (v2.54.x) is the plain-English "why" captured at decision time -
-- the rule that fired (e.g. "Sell List", "Auto-sell (Green)", "Delete List").
-- Optional: when omitted it falls back to a sensible default derived from the
-- path/source tag, so older call sites keep working. This is what /ec history
-- surfaces so the player can see what was sold/deleted AND why.
EC_LogRecentSold = function(itemID, count, path, copper, reason)
    if not itemID then
        return
    end
    EC_compCache.soldLogWrites = EC_compCache.soldLogWrites + 1
    local idx = ((EC_compCache.soldLogWrites - 1) % EC_RECENT_SOLD_LOG_MAX) + 1
    if EC_compCache.soldLogWrites > EC_RECENT_SOLD_LOG_MAX then
        EC_soldLogTrimmed = EC_soldLogTrimmed + 1
    end
    local _, link = GetItemInfo(itemID)
    EC_historySeq = EC_historySeq + 1
    EC_compCache.historySeq = EC_historySeq
    EC_recentSoldLog[idx] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        count = count or 1,
        path = path or "?",
        copper = copper or 0,
        reason = reason or (path == "manual" and "Sold by you" or "Auto-sell rule"),
        loggedAt = date("%H:%M:%S"),
        seq = EC_historySeq,
    }
    EC_compCache.historyDirty = true
end

EC_LogRecentDeleted = function(itemID, count, source, reason)
    if not itemID then
        return
    end
    EC_compCache.deletedLogWrites = EC_compCache.deletedLogWrites + 1
    local idx = ((EC_compCache.deletedLogWrites - 1) % EC_RECENT_DELETED_LOG_MAX) + 1
    if EC_compCache.deletedLogWrites > EC_RECENT_DELETED_LOG_MAX then
        EC_deletedLogTrimmed = EC_deletedLogTrimmed + 1
    end
    local _, link = GetItemInfo(itemID)
    EC_historySeq = EC_historySeq + 1
    EC_compCache.historySeq = EC_historySeq
    EC_recentDeletedLog[idx] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        count = count or 1,
        source = source or "?",
        reason = reason or (source == "auto" and "Auto-delete on pickup" or "Delete List"),
        loggedAt = date("%H:%M:%S"),
        seq = EC_historySeq,
    }
    EC_compCache.historyDirty = true
end

NS.LogRecentSold = EC_LogRecentSold
NS.LogRecentDeleted = EC_LogRecentDeleted
NS.recentSoldLog = EC_recentSoldLog
NS.recentDeletedLog = EC_recentDeletedLog
NS.recentSoldLogMax = EC_RECENT_SOLD_LOG_MAX
NS.recentDeletedLogMax = EC_RECENT_DELETED_LOG_MAX

-- v2.70.0 (competitive-review A4): items SAVED by drain-time re-validation.
-- When a rule or protection changes while the vendor worker is mid-burst,
-- the re-check in DoNextAction skips the destructive call and records the
-- item here so Sold History and /ec bugreport can say WHY nothing
-- happened. Rare by nature (needs a settings change during a run), so the
-- cap is small. Same ring + seq discipline as the sold/deleted logs; on
-- NS/EC_compCache rather than new locals (main chunk is at the Lua 5.1
-- 200-locals cap). kind is "sell" or "delete" (which action was skipped).
NS.recentSavedLog = {}
EC_compCache.savedLogWrites = 0
function EC_compCache.logRecentSaved(itemID, count, kind, reason)
    if not itemID then
        return
    end
    EC_compCache.savedLogWrites = EC_compCache.savedLogWrites + 1
    local idx = ((EC_compCache.savedLogWrites - 1) % 200) + 1
    local _, link = GetItemInfo(itemID)
    EC_historySeq = EC_historySeq + 1
    EC_compCache.historySeq = EC_historySeq
    NS.recentSavedLog[idx] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        count = count or 1,
        kind = kind or "?",
        reason = reason or "?",
        loggedAt = date("%H:%M:%S"),
        seq = EC_historySeq,
    }
    EC_compCache.historyDirty = true
    -- Always announce: a mid-run save means the user JUST changed a rule
    -- and is watching; one line confirms the change took effect in time.
    PrintNicef(L["|cffffd700Kept|r %s - %s"], link or ("item:" .. tostring(itemID)), reason or "?")
end

-- v2.59.4: Process Bags cast log. Session ring buffer of successful
-- Disenchant / Milling / Prospecting / Pick Lock / Convert casts, one
-- entry per successful spell resolution. Captured pre-cast on the
-- panel's PostClick (so the item info is still valid) and committed
-- on UNIT_SPELLCAST_SUCCEEDED matching the pending spell name. Fills
-- the visibility gap in /ec bugreport ("what did I DE this session?")
-- that led to Serv's v2.59.3 worry about accidentally disenchanting a
-- needed affix. Session-local; wiped on /reload.
local EC_RECENT_PROCESSED_LOG_MAX = 200
local EC_recentProcessedLog = {}
local EC_processedLogTrimmed = 0
-- Pending capture between PostClick and UNIT_SPELLCAST_SUCCEEDED.
-- Populated by the panel just before the cast fires (bag/slot/itemID
-- are still valid; the /cast has not yet resolved), consumed by the
-- spellcast handler that matches the same spell name.
EC_compCache.pendingProcessCast = nil

function NS.LogRecentProcessed(entry)
    if not entry or not entry.itemID then
        return
    end
    if #EC_recentProcessedLog >= EC_RECENT_PROCESSED_LOG_MAX then
        table.remove(EC_recentProcessedLog, 1)
        EC_processedLogTrimmed = EC_processedLogTrimmed + 1
    end
    local _, link = GetItemInfo(entry.itemID)
    EC_recentProcessedLog[#EC_recentProcessedLog + 1] = {
        itemID = entry.itemID,
        itemName = entry.itemName or link or ("item:" .. tostring(entry.itemID)),
        mode = entry.mode or "?",
        spellName = entry.spellName or "?",
        count = tonumber(entry.count) or 1,
        loggedAt = date("%H:%M:%S"),
    }
end

NS.recentProcessedLog = EC_recentProcessedLog
NS.recentProcessedLogMax = EC_RECENT_PROCESSED_LOG_MAX
function NS.SessionProcessedTrimmed()
    return EC_processedLogTrimmed
end
-- How many of each log /ec bugreport dumps (a tail slice) so reports stay
-- short even though the logs now hold the whole session.
NS.bugReportRecentMax = EC_BUGREPORT_RECENT_MAX

-- Live trim counts for the Sold History window's "N earlier entries trimmed"
-- note. Returned as (sold, deleted); numbers are value-copied, so this has to
-- be a function rather than a snapshot field.
function NS.SessionHistoryTrimmed()
    return EC_soldLogTrimmed, EC_deletedLogTrimmed
end

-- Wipe the session sell/delete logs (the Sold History window's Clear button)
-- and zero the trim counters so the "trimmed" note resets too.
function NS.ClearSessionHistory()
    wipe(EC_recentSoldLog)
    wipe(EC_recentDeletedLog)
    EC_soldLogTrimmed = 0
    EC_deletedLogTrimmed = 0
    -- Reset the ring write cursors so post-clear writes append from slot 1
    -- again (a stale cursor would leave holes ipairs stops at).
    EC_compCache.soldLogWrites = 0
    EC_compCache.deletedLogWrites = 0
    -- v2.70.0: the saved-items log clears with the rest of the session
    -- history (same Clear button contract).
    wipe(NS.recentSavedLog)
    EC_compCache.savedLogWrites = 0
end

-- Session sell/delete history. Opens the interactive Sold History window
-- (EbonClearance_HistoryWindow.lua): the whole session, newest-first, with
-- All / Sold / Deleted + search filters and a Copy button. Falls back to a
-- plain copyable text dump if that module didn't load. Shared by the
-- /ec history command, the Main panel's Sold History button, and the Alt+
-- Right-Click menu. Session-only - the logs clear on /reload.
function NS.ShowSessionHistory()
    if NS.ShowHistoryWindow then
        NS.ShowHistoryWindow()
        return
    end
    local rows = {}
    local function push(e, action)
        rows[#rows + 1] = {
            at = e.loggedAt or "",
            text = string.format(
                "[%s] %s %dx %s  |cff888888- %s|r",
                tostring(e.loggedAt or "?"),
                action,
                tonumber(e.count) or 1,
                tostring(e.itemName),
                tostring(e.reason or "?")
            ),
        }
    end
    for _, e in ipairs(EC_recentSoldLog) do
        push(e, L["Sold"])
    end
    for _, e in ipairs(EC_recentDeletedLog) do
        push(e, L["Deleted"])
    end
    -- Newest-first. loggedAt is HH:MM:SS, string-sortable within a session.
    table.sort(rows, function(a, b)
        return a.at > b.at
    end)
    local body
    if #rows == 0 then
        body = L["Nothing sold or deleted yet this session."]
    else
        local lines = {}
        for i = 1, #rows do
            lines[i] = rows[i].text
        end
        body = table.concat(lines, "\n")
    end
    if NS.ShowCopyFrame then
        NS.ShowCopyFrame(L["EbonClearance: Session History"], body)
    else
        PrintNice(body)
    end
end

-- v2.51.0: watch-list toggle snapshot at PLAYER_LOGIN, after EnsureDB.
-- The watch list is a curated set of high-diagnostic-value toggles - the
-- ones that meaningfully change addon behaviour and that a user might
-- flip mid-session. /ec bugreport diffs this snapshot against the live
-- values to surface "toggles you changed this session". No mutation
-- hooks; the diff at report time is enough.
--
-- Not exhaustive on purpose: cosmetic toggles (tint colours, border
-- widths) don't affect what the addon does, so they're excluded.
local EC_TOGGLE_WATCH_LIST = {
    -- destructive
    "enableDeletion", "autoDeleteOnPickup", "autoDeleteGreyOnLoot",
    "announceAutoDelete", "warnConflictingAddons",
    -- auto-mark
    "autoMarkAffixDupes", "autoMarkResilience", "autoMarkKnownUnsellableRecipes",
    -- protection
    "protectAllTomes", "protectUnlearnedTomes", "protectAffixedRareItems",
    "protectChanceOnHitItems", "affixAllowExactDupes", "keepBoeAffixDupes",
    "keepBoeBelowRankFloor",
    -- auto-protect (equipped / upgrades / sets)
    "autoAddEquipped", "autoProtectUpgrades", "autoProtectEquipmentSets",
    -- sell rules
    "sellKnownRecipes",
    -- vendor mode
    "merchantMode", "repairGear", "repairUseGuildBank",
    -- scavenger
    "summonGreedy", "muteGreedy", "autoLootCycle", "restoreScavengerAfterLoad",
    -- sharing (v2.53.0)
    "shareGuildData", "shareGuildName", "shareChanceProcs",
    -- realm-wide sharing (v2.58.0)
    "shareServerData",
}
local EC_toggleLoginSnapshot = nil
local function EC_CaptureToggleLoginSnapshot()
    if not DB then
        return
    end
    EC_toggleLoginSnapshot = {}
    for i = 1, #EC_TOGGLE_WATCH_LIST do
        local k = EC_TOGGLE_WATCH_LIST[i]
        EC_toggleLoginSnapshot[k] = DB[k]
    end
end
local function EC_ToggleDiffSinceLogin()
    if not (EC_toggleLoginSnapshot and DB) then
        return {}
    end
    local diffs = {}
    for i = 1, #EC_TOGGLE_WATCH_LIST do
        local k = EC_TOGGLE_WATCH_LIST[i]
        local before = EC_toggleLoginSnapshot[k]
        local now = DB[k]
        if before ~= now then
            diffs[#diffs + 1] = { key = k, before = before, now = now }
        end
    end
    return diffs
end
NS.CaptureToggleLoginSnapshot = EC_CaptureToggleLoginSnapshot
NS.ToggleDiffSinceLogin = EC_ToggleDiffSinceLogin
NS.toggleWatchList = EC_TOGGLE_WATCH_LIST

-- v2.51.0: prime the client's item cache for Delete List entries at
-- login. GetItemInfo returns nil for items the client hasn't seen this
-- session; Delete List entries persist across sessions and often
-- haven't been hovered, so /ec bugreport's Delete List Preview shows
-- "item:ID" for everything on a fresh login. SetHyperlink fires an
-- async client-cache request; by the time the user runs /ec bugreport
-- later in the session, the client has received the responses and
-- names resolve properly. The single-sweep is fine for the typical
-- delete-list size (100-500 entries) - the client batches these
-- server-side and the burst settles in a couple of seconds.
local function EC_PrimeDeleteListItemCache()
    if not (DB and DB.deleteList) then
        return
    end
    local st = NS.scanTooltip
    if not st then
        return
    end
    for id in pairs(DB.deleteList) do
        if type(id) == "number" then
            pcall(st.SetOwner, st, UIParent, "ANCHOR_NONE")
            pcall(st.ClearLines, st)
            pcall(st.SetHyperlink, st, "item:" .. id)
        end
    end
end
NS.PrimeDeleteListItemCache = EC_PrimeDeleteListItemCache

-- v2.51.0: last-run timestamps for the addon's driving events. When a
-- user reports "auto-mark isn't firing" or "the vendor cycle got stuck",
-- knowing WHEN each subsystem last ran narrows the search: an
-- EQUIPMENT_SETS_CHANGED that fired 2 hours ago vs. never is a
-- meaningful signal. `date()` is enUS-locale-safe (24h format).
-- Values start as nil and remain nil until the event actually fires
-- so a "never" in the bug report is diagnostic in its own right.
local EC_lastEventAt = {
    bagUpdate = nil,          -- BAG_UPDATE debounce settled
    equipmentSetsChanged = nil,
    merchantShow = nil,
    merchantClosed = nil,
    autoMarkAffix = nil,      -- runAutoMarkAffixDupes ran to completion
    autoMarkResilience = nil, -- runAutoMarkResilience ran to completion
    autoMarkKnownRecipe = nil, -- runAutoMarkKnownUnsellableRecipes ran to completion
    vendorRunStart = nil,     -- StartRun fired
    autoDeleteScan = nil,     -- runAutoDeleteOnPickup ran
}
EC_StampEvent = function(key)
    -- Store the cheap epoch integer; /ec bugreport formats it to HH:MM:SS at
    -- render time. date("%H:%M:%S") here was a strftime + string alloc per
    -- stamp, and one call site sits on the RAW (un-coalesced) BAG_UPDATE /
    -- ITEM_LOCK_CHANGED path where it ran once per event during AOE loot.
    EC_lastEventAt[key] = time()
end
NS.lastEventAt = EC_lastEventAt
NS.StampEvent = EC_StampEvent

-- v2.44.0: auto-mark Resilience PvP gear for deletion. When the
-- toggle is on, every BAG_UPDATE scans bags for items with a
-- "Resilience" tooltip line and adds them to the Delete List (one
-- chat line per add). The actual destruction is handled by the
-- existing vendor cycle or auto-delete-on-pickup - this function
-- only adds entries to the list. Gates symmetrically with the
-- auto-delete sweep so the master Enable toggle vetoes the whole
-- destructive pipeline.
function EC_compCache.runAutoMarkResilience()
    local DB = NS.DB
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if not (DB and DB.autoMarkResilience) then
        return
    end
    EC_StampEvent("autoMarkResilience")
    if EC_compCache.vendorRunning then
        return
    end
    -- Skip items that are already on a curated list. Keep List wins
    -- (the player has explicitly said "do not touch"); items already
    -- on the Delete List are a no-op.
    local deleteList = DB.deleteList
    if not deleteList then
        return
    end
    local keepList = DB.blacklist
    local accountKeep = NS.ADB and NS.ADB.whitelist
    -- v2.59.0: iterate the shared flush snapshot. Runs after the pickup-
    -- delete scan (which can synchronously empty one slot mid-flush), so
    -- the live slot is re-verified against the snapshotted itemID before
    -- the tooltip scan - itemHasResilience caches by itemID, and scanning
    -- a changed slot would poison that cache.
    local snap = EC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        do -- scoping block keeps the old two-level loop body untouched
            local e = snap.entries[i]
            local id = e.itemID
            if id and not deleteList[id] and GetContainerItemID(e.bag, e.slot) == id then
                local protectedByKeep = (keepList and keepList[id])
                    or (accountKeep and accountKeep[id])
                if not protectedByKeep then
                    if EC_compCache.itemHasResilience(e.bag, e.slot, id) then
                        -- v2.44.0 iter: only mark UNSELLABLE Resilience
                        -- gear (sellPrice 0 / nil). The original
                        -- feedback (Murlocked: "delete pvp item with
                        -- resillience (they are unsellable)") was
                        -- specifically about gear the vendor refuses.
                        -- A real player report on this iteration: green
                        -- Slippers of Serenity / Pauldrons of Sufferance
                        -- with Resilience BUT a vendor price (2g+)
                        -- were getting auto-deleted - the user
                        -- reasonably expected those to be sold instead.
                        -- Skip anything sellable; the normal sell rules
                        -- handle them (Sell List, quality rule).
                        -- v2.60.0: also destructure `quality` (3rd return)
                        -- so the announce gate can consult
                        -- DB.announceAutoDeleteQualities[quality].
                        local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
                        if sellPrice and sellPrice > 0 then -- luacheck: ignore 542
                            -- Sellable; let the vendor cycle do its
                            -- job. Don't fall through to the next
                            -- slot via `return` - the BAG_UPDATE
                            -- coalescing keeps the rest of the bag
                            -- in scope for this same sweep.
                        else
                            deleteList[id] = true
                            -- v2.50.3: session ring-buffer log for /ec bugreport.
                            EC_LogAutoMark(id, "resilience")
                            if EC_compCache.shouldAnnounceAutoDelete(quality) then
                                local link = select(2, GetItemInfo(id)) or ("item:" .. tostring(id))
                                -- v2.50.2: append recovery hint so the player
                                -- has a path back if the auto-mark caught an
                                -- item they wanted to keep.
                                PrintNicef(
                                    L["|cffff4444Marked for deletion (Resilience, unsellable):|r %s"]
                                        .. " "
                                        .. L["|cffaaaaaaAdd to Keep List (Alt+Right-Click on the bag slot) to save it.|r"],
                                    link
                                )
                            end
                            -- One add per BAG_UPDATE fire keeps the
                            -- chat tidy if the player loots multiple
                            -- PvP pieces at once; the next BAG_UPDATE
                            -- (any bag event re-fires the debounce)
                            -- picks up the next one.
                            return
                        end
                    end
                end
            end
        end
    end
end

-- v2.47.0: auto-mark UNSELLABLE affixes for deletion. When the toggle is on,
-- scans bags for affixed Rare/Epic items that EC would otherwise sell -
-- anything affixDisposable releases: a dupe you own, or a rank below your "Sell
-- affixes below rank" floor - that are soulbound AND have no vendor value, and
-- adds them to the Delete List (one chat line per add). These are exactly the
-- items that would otherwise get flagged "will sell" yet stick in the bag
-- forever because the merchant refuses them (no vendor price). Affixes EC keeps
-- (a rank still being collected) are never touched. Items with a vendor price
-- are left to the sell path - the player keeps the gold. Destruction is handled
-- by the vendor cycle or auto-delete-on-pickup, never here. Gated like the
-- other destructive scans (master Enable + enableDeletion) AND requires affix
-- protection on (protectAffixedRareItems): the feature is only meaningful for
-- the affixed items protection is otherwise KEEPING, and the Delete-List affix
-- gate (deleteListSlotEligible, which re-checks affixDisposable per instance)
-- only runs when protection is on. It does NOT require the "sell exact-rank
-- dupes" toggle. Asked for by Broyo.
-- v2.57.2: item levels at/above this are "real gear" and are never auto-marked
-- for deletion by the unsellable-affix feature. On Project Ebonhold even top-end
-- soulbound gear has sellPrice 0, so "no vendor value" alone is NOT a safe
-- "trash" signal - a high-iLvl drop must be protected. Tunable.
--
-- v2.60.0 (Serv report): raised from 100 to 200. On a WotLK-max character
-- most gear sits above iLvl 100 - the old threshold protected essentially
-- everything, including mid-BC-era drops the player doesn't care about.
-- 200 keeps real endgame gear safe (Ulduar / ToC / ICC drops all sit
-- above) while letting the auto-mark scan catch old low-mid-iLvl PvP
-- dupes and BC-era drops. Users who want tighter or looser protection
-- can toggle DB.automarkProtectHighILvl off entirely (unlocks all iLvls
-- for auto-mark, safe if the Keep List / Sets / Equipped tags cover
-- everything important).
local EC_AUTOMARK_PROTECT_ILVL = 200

-- v2.57.2 SAFETY: shared "is this item protected from auto-mark deletion?" gate,
-- called by BOTH runAutoMarkAffixDupes (the real marking) and the tooltip's
-- "Will Delete (unsellable affix)" preview so the two can't drift (Serv report:
-- an equipment-set-member ring/shirt showed a false "Will Delete" while the real
-- logic skipped it). Covers the itemID-keyed protections: equipment-set
-- membership, the account Sell List, currently-equipped, quest items, and high
-- item level. (The character Keep List, tomes, and baseline tools are checked by
-- each caller in its own context.)
-- v2.60.0 (Serv follow-up): also returns a second value naming the
-- SPECIFIC reason the item is protected, so the tooltip's "Keep
-- (protected)" label can be more precise. Reason keys are canonical
-- English tokens ("set" / "sellList" / "equipped" / "quest" /
-- "highIlvl") the tooltip / trace map to localized strings. Callers
-- that only need the boolean still work unchanged (they read the first
-- return and ignore the second).
function EC_compCache.itemProtectedFromAutoMarkDelete(id)
    if not id then
        return false
    end
    if EC_compCache.equipmentSetIDs and EC_compCache.equipmentSetIDs[id] then
        return true, "set"
    end
    local ADB = NS.ADB
    if ADB and ADB.whitelist and NS.IsInSet and NS.IsInSet(ADB.whitelist, id) then
        return true, "sellList"
    end
    if IsEquippedItem and IsEquippedItem(id) then
        return true, "equipped"
    end
    if EC_compCache.isQuestItem and EC_compCache.isQuestItem(id) then
        return true, "quest"
    end
    if DB and DB.automarkProtectHighILvl ~= false then
        local _, _, _, ilvl = GetItemInfo(id)
        if ilvl and ilvl >= EC_AUTOMARK_PROTECT_ILVL then
            return true, "highIlvl"
        end
    end
    return false
end

function EC_compCache.runAutoMarkAffixDupes()
    local DB = NS.DB
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if not (DB and DB.enableDeletion and DB.autoMarkAffixDupes) then
        return
    end
    EC_StampEvent("autoMarkAffix")
    if not DB.protectAffixedRareItems then
        return
    end
    if EC_compCache.vendorRunning then
        return
    end
    local deleteList = DB.deleteList
    if not deleteList then
        return
    end
    local keepList = DB.blacklist
    local accountKeep = NS.ADB and NS.ADB.whitelist
    -- v2.50.2: honour equipment-set membership as user intent. The cache
    -- is rebuilt on EQUIPMENT_SETS_CHANGED regardless of the auto-protect
    -- toggle. v2.57.2 SAFETY (Serv): force a FRESH sync on every scan rather
    -- than only lazy-priming when nil. The lazy-prime left a stale cache the
    -- one time it mattered - a set member added or edited after login could
    -- be auto-marked because the cache never refreshed. A full re-sync each
    -- debounced scan also re-stamps set members onto the Keep List (Serv
    -- request: saved-set items stay Keep-protected for safety). Bounded work:
    -- a few sets of ~19 slots on the already-debounced BAG_UPDATE path.
    if EC_compCache.syncEquipmentSets then
        EC_compCache.syncEquipmentSets(true)
    end
    local setMembers = EC_compCache.equipmentSetIDs
    -- v2.59.0: iterate the shared flush snapshot. Snapshot-quality pre-gate:
    -- PE affixes exist only on Rare (3) / Epic (4), so entries KNOWN to be
    -- sub-rare skip every protection lookup and tooltip scan below; nil /
    -- -1 (uncached) entries fall through to the authoritative GetItemInfo
    -- quality check, never to a skip. Runs after the pickup-delete scan, so
    -- the live slot is re-verified against the snapshotted itemID before
    -- the per-slot tooltip work (tome / affix / bind scans cache by item).
    local snap = EC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        do -- scoping block keeps the old two-level loop body untouched
            local e = snap.entries[i]
            local id = e.itemID
            if id
                and not deleteList[id]
                and (e.quality == nil or e.quality < 0 or e.quality >= 3)
                and GetContainerItemID(e.bag, e.slot) == id
            then
                local protectedByKeep = (keepList and keepList[id])
                    or (accountKeep and accountKeep[id])
                    or (setMembers and setMembers[id])
                -- Respect every other protection: Keep List, equipped, quest
                -- items, tomes/recipes, and baseline profession tools are
                -- never auto-marked. v2.57.2 adds the shared strong guard
                -- (itemProtectedFromAutoMarkDelete) so high item-level "real
                -- gear", set members, and quest rewards can never be marked -
                -- the same gate the tooltip preview uses, so they can't drift.
                if not protectedByKeep
                    and not IsEquippedItem(id)
                    and not (EC_compCache.isQuestItem and EC_compCache.isQuestItem(id))
                    and not (EC_compCache.itemIsTome and EC_compCache.itemIsTome(e.bag, e.slot, id))
                    and not (EC_compCache.baselineProtectedIDs and EC_compCache.baselineProtectedIDs[id])
                    and not EC_compCache.itemProtectedFromAutoMarkDelete(id)
                then
                    local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
                    if quality and quality >= 3 then
                        local affix = EC_compCache.bagSlotAffixData(e.bag, e.slot)
                        -- Mark any affix EC would otherwise SELL (a dupe you
                        -- own, or a rank below your "Sell affixes below rank"
                        -- floor - the shared affixDisposable check) that is
                        -- soulbound (can't auction/trade) AND has no vendor
                        -- value (can't be sold). Those are the ones that would
                        -- otherwise be flagged "will sell" yet stick in the bag
                        -- forever because the merchant refuses them. Affixes EC
                        -- keeps (still being collected) are left alone.
                        if affix and EC_compCache.affixDisposable(affix) then
                            -- v2.48.1 refinement: don't auto-mark items where
                            -- the release reason is rankBelow-ONLY AND the
                            -- player doesn't own this affix at this rank.
                            -- The floor policy is "sell low-rank if I can";
                            -- for unsellable items the sell path is inert,
                            -- and keeping the item for extraction is more
                            -- valuable than deleting it with no gold gained.
                            -- Only fires when rank<floor is the SOLE reason
                            -- affixDisposable returned true (manualAllow /
                            -- owned-dupe releases still auto-mark).
                            local affixKey = affix.description
                                and EC_compCache.normaliseAffixDesc
                                and EC_compCache.normaliseAffixDesc(affix.description)
                            local ADB2 = NS.ADB
                            local manualAllow = affixKey and ADB2 and ADB2.allowedAffixes and ADB2.allowedAffixes[affixKey]
                            local playerOwns = EC_compCache.playerOwnsAffix
                                and EC_compCache.playerOwnsAffix(affix)
                            local rankBelowOnly = (not manualAllow)
                                and (not playerOwns)
                                and DB.affixMinSellRank
                                and DB.affixMinSellRank > 0
                                and affix.rank
                                and affix.rank < DB.affixMinSellRank
                            if rankBelowOnly then -- luacheck: ignore 542
                                -- Skip; item stays for extraction.
                            else
                            local soulbound = EC_compCache.getBindType(e.bag, e.slot) == "bop"
                            local noValue = not (sellPrice and sellPrice > 0)
                            if soulbound and noValue then
                                deleteList[id] = true
                                -- v2.50.3: session ring-buffer log for /ec bugreport.
                                EC_LogAutoMark(id, "affix")
                                if EC_compCache.shouldAnnounceAutoDelete(quality) then
                                    local link = select(2, GetItemInfo(id)) or ("item:" .. tostring(id))
                                    -- v2.50.2: append recovery hint so the
                                    -- player has a path back if the auto-mark
                                    -- caught an item they wanted to keep.
                                    PrintNicef(
                                        L["|cffff4444Marked for delete|r %s - affix you can't sell (no vendor value)."]
                                            .. " "
                                            .. L["|cffaaaaaaAdd to Keep List (Alt+Right-Click on the bag slot) to save it.|r"],
                                        link
                                    )
                                end
                                -- One add per BAG_UPDATE fire (mirrors the
                                -- resilience auto-mark); the next bag event
                                -- re-fires the debounce for the next item.
                                return
                            end
                            end -- else (rankBelowOnly branch)
                        end
                    end
                end
            end
        end
    end
end

-- v2.60.0 (Serv report, Recipe: Haunted Herring / Recipe: Last Week's Mammoth):
-- auto-mark learned profession recipes with sellPrice 0 for deletion. Some
-- BoP profession recipes (Cooking recipes at low ranks, some low-level Skinning /
-- Lockpicking schematics) return sellPrice 0 from GetItemInfo, so "Sell Known
-- Recipes" can't do anything with them (vendor refuses). When this toggle is on,
-- and the parent sellKnownRecipes toggle is also on, learned unsellable recipes
-- are added to the Delete List instead. Skips Keep List / equipment-set /
-- currently-equipped / quest / non-recipe tomes. Announce goes through the
-- shared per-rarity chat filter (announceAutoDeleteQualities). Gated like the
-- other destructive scans (master Enable + enableDeletion).
function EC_compCache.runAutoMarkKnownUnsellableRecipes()
    local DB = NS.DB
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if not (DB and DB.enableDeletion and DB.autoMarkKnownUnsellableRecipes) then
        return
    end
    if not DB.sellKnownRecipes then
        return
    end
    EC_StampEvent("autoMarkKnownRecipe")
    -- EC-TRAP: this scan deliberately does NOT consult protectAllTomes /
    -- protectUnlearnedTomes. It rides the same documented carve-out as
    -- EC_IsSellable's recipePass ("Sell Known Recipes overrides the tome
    -- veto for LEARNED recipes"): the feature only exists for learned,
    -- unsellable recipes, and it requires three explicit opt-ins
    -- (enableDeletion + autoMarkKnownUnsellableRecipes + sellKnownRecipes).
    -- Adding a protectAllTomes guard here would make the toggle silently
    -- inert for exactly the users who asked for it. Unlearned recipes are
    -- never touched (playerKnowsTomeSpell gate below).
    if EC_compCache.vendorRunning then
        return
    end
    local deleteList = DB.deleteList
    if not deleteList then
        return
    end
    local keepList = DB.blacklist
    local accountKeep = NS.ADB and NS.ADB.whitelist
    local setMembers = EC_compCache.equipmentSetIDs
    local snap = EC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        do
            local e = snap.entries[i]
            local id = e.itemID
            if id and not deleteList[id] and GetContainerItemID(e.bag, e.slot) == id then
                local protectedByKeep = (keepList and keepList[id])
                    or (accountKeep and accountKeep[id])
                    or (setMembers and setMembers[id])
                if not protectedByKeep
                    and not IsEquippedItem(id)
                    and not (EC_compCache.isQuestItem and EC_compCache.isQuestItem(id))
                then
                    local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
                    if not (sellPrice and sellPrice > 0)
                        and EC_compCache.itemIsTome
                        and EC_compCache.tomeKind
                        and EC_compCache.playerKnowsTomeSpell
                        and EC_compCache.itemIsTome(e.bag, e.slot, id)
                        and EC_compCache.tomeKind(id) == "Recipe"
                        and EC_compCache.playerKnowsTomeSpell(e.bag, e.slot, id)
                    then
                        deleteList[id] = true
                        EC_LogAutoMark(id, "knownRecipe")
                        if EC_compCache.shouldAnnounceAutoDelete(quality) then
                            local link = select(2, GetItemInfo(id)) or ("item:" .. tostring(id))
                            PrintNicef(
                                L["|cffff4444Marked for delete|r %s - recipe you know (no vendor value)."]
                                    .. " "
                                    .. L["|cffaaaaaaAdd to Keep List (Alt+Right-Click on the bag slot) to save it.|r"],
                                link
                            )
                        end
                        return
                    end
                end
            end
        end
    end
end

local function BuildQueue(junkOnly)
    wipe(queue)
    queueIndex = 1
    goldThisVendoring = 0
    -- v2.70.0 (competitive-review A4): stash the run's junkOnly context so
    -- DoNextAction can re-run EC_IsSellable with the SAME merchant-mode
    -- restriction at drain time. On EC_compCache (main chunk is at the
    -- Lua 5.1 200-locals cap).
    EC_compCache.runJunkOnly = junkOnly and true or false
    -- Single bag walk that produces both the sell and delete queue entries.
    --
    -- v2.37.0 reversed the per-slot dispatch order. Pre-v2.37.0 the sell
    -- pass ran first and only fell through to the delete-list check when
    -- EC_IsSellable returned false. Result: a grey item on the Delete
    -- List had isJunk = true, got queued as "sell", and the user's
    -- explicit "destroy this" intent silently lost to greyAutoSell. The
    -- bag-slot tint + tooltip annotation already followed the inverse
    -- precedence ("delete" tint wins over sell verdicts) so the cycle's
    -- order disagreed with what the UI was telling the player. Now the
    -- Delete-List check fires first per slot: an item on the list (with
    -- Enable Deletion on, passing the affix protection check) is queued
    -- as "delete" regardless of any sell signal. Sell branch only runs
    -- when the slot didn't queue a delete. Matches the bag-tint logic
    -- in EbonClearance_BagDisplay.lua's bagSlotWillSellCategory (delete
    -- first) and the new Delete-List step in describeSellability.
    local deletionOn = DB.enableDeletion == true
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local queuedDelete = false
            if deletionOn then
                -- v2.42.0: policy now lives in the shared helper (also used by
                -- the auto-delete-on-pickup scan) so the two never drift.
                local id, count, quality = EC_compCache.deleteListSlotEligible(bag, slot)
                if id then
                    queue[#queue + 1] = {
                        type = "delete",
                        bag = bag,
                        slot = slot,
                        itemID = id,
                        count = count,
                        quality = quality,
                    }
                    queuedDelete = true
                end
            end
            if not queuedDelete then
                -- v2.46.4: cheap pre-check for the vendor-refused
                -- guard. EC_IsSellable does a tooltip scan + multiple
                -- API hits; skip it on slots we already know the
                -- vendor refused this cycle. Equality on itemID is
                -- the discriminator - empty slot or different item
                -- in slot = nil/changed, so the check fails and the
                -- new item gets a fair try.
                local refusedID = EC_vendorRefusedThisRun[EC_refusalKey(bag, slot)]
                local skipForRefusal = refusedID and refusedID == GetContainerItemID(bag, slot)
                local sellable, link, itemID, sellPrice, itemCount, quality
                if not skipForRefusal then
                    sellable, link, itemID, sellPrice, itemCount, quality = EC_IsSellable(bag, slot, junkOnly)
                end
                if sellable then
                    -- v2.37.0: rarity is captured at queue-build time so the
                    -- worker path can attribute the sell to a quality bucket
                    -- without re-querying GetItemInfo at action execution;
                    -- EC_IsSellable already computed it, so it rides along on
                    -- the return tuple instead of a second GetItemInfo here.
                    -- Plain-English "why" for the session decision log, built
                    -- from the exact signal EC_IsSellable just recorded
                    -- (EC_compCache.lastSellSignal) so the history explanation
                    -- can't drift from the real sell logic. Read here, right
                    -- after the EC_IsSellable call above, before any other
                    -- EC_IsSellable runs.
                    local sellReason = EC_compCache.sellReasonForSignal
                        and EC_compCache.sellReasonForSignal(
                            EC_compCache.lastSellSignal,
                            quality,
                            DB.qualityRules and DB.qualityRules[quality]
                        )
                        or nil
                    queue[#queue + 1] = {
                        type = "sell",
                        bag = bag,
                        slot = slot,
                        itemID = itemID,
                        count = itemCount,
                        price = sellPrice or 0,
                        quality = quality,
                        reason = sellReason,
                    }
                    if sellPrice and sellPrice > 0 then
                        goldThisVendoring = goldThisVendoring
                            + EC_GetItemPrice(link, itemID, sellPrice, itemCount)
                    end
                end
            end
        end
    end

    local cap = EC_EffectiveMaxItemsPerRun()
    if #queue > cap then
        local removed = #queue - cap
        for i = #queue, cap + 1, -1 do
            queue[i] = nil
        end
        PrintNicef(L["|cffffff00Sold %d items this trip (%d more left). Talk to the merchant again to sell the rest.|r"], cap, removed)
    end
end

local function FinishRun()
    EC_compCache.vendorRunning = false
    worker:Hide()

    -- v2.38.1: helper writes to DB + ADB.accountStats.
    EC_BumpStat("totalCopper", goldThisVendoring or 0)
    EC_session.copper = EC_session.copper + (goldThisVendoring or 0)
    -- v2.72.1 (Serv report, Winterfall Firewater at Mei Francis): the
    -- batch counter used to add the WHOLE queue as "Sold", so a run of
    -- pure Delete-List actions announced "Sold 7 items ... 0g 0s 0c".
    -- Count sells and deletes separately so the summary tells the truth.
    -- (Counter lives on EC_compCache - the main chunk is at the
    -- 200-locals cap.)
    do
        local sold, deleted = 0, 0
        for i = 1, #queue do
            if queue[i].type == "delete" then
                deleted = deleted + 1
            else
                sold = sold + 1
            end
        end
        EC_batchTotalSold = EC_batchTotalSold + sold
        EC_compCache.batchTotalDeleted = (EC_compCache.batchTotalDeleted or 0) + deleted
    end
    EC_batchTotalGold = EC_batchTotalGold + (goldThisVendoring or 0)
    -- v2.37.0: attribute the auto-cycle haul to the current zone so the
    -- Stats panel's "Top Zones" rollup tracks worker sells too.
    if (goldThisVendoring or 0) > 0 then
        EC_compCache.attributeCopperToZone(goldThisVendoring)
    end

    -- One summary builder for the mid-run and final lines below, so the
    -- three exit paths can't drift on wording. Deletes get their own
    -- phrasing; the classic sold-only lines are unchanged.
    local function EC_BatchSummary(final)
        local deleted = EC_compCache.batchTotalDeleted or 0
        if final then
            if deleted > 0 and EC_batchTotalSold > 0 then
                return string.format(
                    L["Vendoring complete! Sold |cffffff00%d|r and deleted |cffff4444%d|r items. |cffb6ffb6Money Collected:|r %s"],
                    EC_batchTotalSold,
                    deleted,
                    CopperToColoredText(EC_batchTotalGold)
                )
            elseif deleted > 0 then
                return string.format(
                    L["Vendoring complete! Deleted |cffff4444%d|r Delete List items. Nothing sold."],
                    deleted
                )
            end
            return string.format(
                L["Vendoring complete! Sold |cffffff00%d|r items. |cffb6ffb6Money Collected:|r %s"],
                EC_batchTotalSold,
                CopperToColoredText(EC_batchTotalGold)
            )
        end
        if deleted > 0 and EC_batchTotalSold > 0 then
            return string.format(
                L["Sold |cffffff00%d|r and deleted |cffff4444%d|r so far. Checking for more..."],
                EC_batchTotalSold,
                deleted
            )
        elseif deleted > 0 then
            return string.format(L["Deleted |cffff4444%d|r so far. Checking for more..."], deleted)
        end
        return string.format(L["Sold |cffffff00%d|r items so far. Checking for more..."], EC_batchTotalSold)
    end

    -- Check if merchant is still open - delay re-scan so server can process sold items
    if MerchantFrame and MerchantFrame:IsShown() then
        PrintNice(EC_BatchSummary(false))
        EC_Delay(1.0, function()
            if not MerchantFrame or not MerchantFrame:IsShown() then
                return
            end
            local merchantAllowed = EC_IsMerchantAllowed()
            BuildQueue(not merchantAllowed)
            if #queue > 0 then
                EC_compCache.vendorRunning = true
                worker.t = 0
                worker:Show()
            else
                -- Nothing left - print final summary
                PrintNice(EC_BatchSummary(true))
                -- v2.13.3: hoisted EC_SummonGreedyWithDelay out of an
                -- if/else where both branches called it unconditionally.
                -- Only the lootCycleState transition was branch-specific.
                if DB and DB.autoLootCycle then
                    EC_compCache.lootCycleState = STATE.IDLE
                end
                -- v2.14.0: arm the resummon-print debounce on every
                -- merchant-cycle close-out, not just bag-full-triggered
                -- cycles. SummonGreedyScavenger's already-out branch
                -- clears the flag silently if the Scavenger was never
                -- dismissed (e.g. user sold only greys at a normal
                -- vendor without the Goblin cycle), so this can't
                -- spuriously print. The previous behaviour only set
                -- the flag in EC_HandleBagFullForCycle, so manual
                -- merchant visits silently summoned the Scavenger
                -- without the chat acknowledgement.
                EC_compCache.pendingAnnounce = true
                EC_SummonGreedyWithDelay()
            end
        end)
        return
    end

    -- All done - print final summary
    PrintNice(EC_BatchSummary(true))

    if DB and DB.autoLootCycle then
        EC_compCache.lootCycleState = STATE.IDLE
    end
    -- v2.14.0: see comment at the corresponding call above.
    EC_compCache.pendingAnnounce = true
    EC_SummonGreedyWithDelay()
end

local function DoNextAction()
    -- v2.38.2: Turbo Mode runs a batch of N DoNextAction calls per tick
    -- (in the OnUpdate batch loop below). When the queue exhausts mid-batch,
    -- the remaining iterations would re-enter the `not action` branch and
    -- re-fire FinishRun N-1 extra times - resulting in N x "Vendoring
    -- complete!" chat spam AND N x bumps of DB.totalCopper / EC_session.copper.
    -- FinishRun sets vendorRunning to false, so checking it here gates
    -- the post-finish iterations. Belt-and-braces with the batch loop's
    -- own break below.
    if not EC_compCache.vendorRunning then
        return
    end
    if not MerchantFrame or not MerchantFrame:IsShown() then
        EC_compCache.vendorRunning = false
        worker:Hide()
        return
    end

    local action = queue[queueIndex]
    if not action then
        FinishRun()
        return
    end

    -- Safety: verify the item at this slot still matches what we queued.
    -- Bags can shift between queue build and execution (player moves items, etc).
    local currentID = GetContainerItemID(action.bag, action.slot)
    if currentID ~= action.itemID then
        queueIndex = queueIndex + 1
        return
    end

    if action.type == "sell" then
        -- v2.70.0 (competitive-review A4): drain-time re-validation. The
        -- queue was built at StartRun; the user can change a rule while the
        -- worker is mid-burst (Turbo runs up to 80 actions). Re-run the
        -- full sell predicate against CURRENT settings immediately before
        -- the destructive call; when it no longer passes, the item is
        -- SAVED - logged with a reason so Sold History and /ec bugreport
        -- show why nothing happened. Cheap second run: every tooltip-backed
        -- cache is warm from BuildQueue. Deliberately does NOT write the
        -- vendor-refusal mark (nothing was attempted).
        if not EC_IsSellable(action.bag, action.slot, EC_compCache.runJunkOnly) then
            EC_compCache.logRecentSaved(action.itemID, action.count, "sell",
                L["Rules changed during the run - no longer matches a sell rule."])
            queueIndex = queueIndex + 1
            return
        end
        -- v2.9.0: bracket the worker-path UseContainerItem so the
        -- manual-sell hook (installed at ADDON_LOADED) skips this call.
        -- The counters below own the attribution for the worker path.
        EC_manualSell.inSelfSell = true
        UseContainerItem(action.bag, action.slot)
        EC_manualSell.inSelfSell = false
        -- v2.46.4: mark this slot as "attempted" for the vendor-refused
        -- guard. Verification happens at the next BuildQueue (after the
        -- 1s inter-batch gate in FinishRun) when the slot has had time
        -- to empty for a successful sale. If the SAME itemID is still
        -- there at re-scan time, the vendor refused and BuildQueue
        -- skips it. Successful sales leave the slot empty / different,
        -- so the equality check fails and the entry is implicitly
        -- stale (cleared on the next StartRun anyway).
        if action.itemID then
            EC_vendorRefusedThisRun[EC_refusalKey(action.bag, action.slot)] = action.itemID
        end
        -- v2.38.1: helpers write to DB + ADB.accountStats.
        local soldCount = action.count or 1
        EC_BumpStat("totalItemsSold", soldCount)
        EC_session.sold = EC_session.sold + soldCount
        if action.itemID then
            EC_BumpStatBucket("soldItemCounts", action.itemID, soldCount)
        end
        local soldCopper = 0
        if action.quality then
            soldCopper = (action.price or 0) * soldCount
            EC_BumpStatBucket("soldItemsByQuality", action.quality, soldCount)
            EC_BumpStatBucket("soldCopperByQuality", action.quality, soldCopper)
        end
        -- v2.51.0: recent-sold ring buffer for /ec bugreport.
        EC_LogRecentSold(action.itemID, soldCount, "worker", soldCopper, action.reason)
    elseif action.type == "delete" then
        -- v2.70.0 (competitive-review A4): drain-time re-validation, delete
        -- side. deleteListSlotEligible IS the full live gate (Keep/Sell
        -- list vetoes, equipped, affix protection, quest) - re-run it so a
        -- protection toggled mid-burst saves the item, with the reason
        -- logged. EC-TRAP: reuse the shared helper, do NOT inline a subset
        -- of its checks here (the same drift rule as the auto-delete scans).
        if not EC_compCache.deleteListSlotEligible(action.bag, action.slot) then
            EC_compCache.logRecentSaved(action.itemID, action.count, "delete",
                L["Protection changed during the run - delete skipped."])
            queueIndex = queueIndex + 1
            return
        end
        EC_compCache.executeBagSlotDelete(action.bag, action.slot, action.itemID, action.count, action.quality, false)
    end

    queueIndex = queueIndex + 1
end

-- The 0.05s interval floor is an anti-disconnect guarantee, not a performance
-- tuning choice. Faster per-item pacing floods the server with UseContainerItem
-- packets and trips a server-side rate limit that boots the client. See
-- docs/ADDON_GUIDE.md "Performance rules" and v2.0.11 in the README changelog.
-- v2.37.7: Turbo Mode pops EC_EffectiveBatchSize() items per fire. The
-- default batch (1) preserves the v2.0.11 invariant exactly; the opt-in
-- larger batch is gated on DB.turboMode and capped so the per-frame
-- packet count stays bounded.
worker:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    local interval = EC_EffectiveVendorInterval()
    if self.t >= interval then
        self.t = 0
        local batch = EC_EffectiveBatchSize()
        local _spikeT0 = EC_prof and EC_prof()
        for _ = 1, batch do
            DoNextAction()
            -- v2.38.2: stop iterating the moment FinishRun fires. The
            -- alternative is queue-exhausted DoNextAction calls
            -- repeating FinishRun once per remaining batch slot.
            if not EC_compCache.vendorRunning then
                break
            end
        end
        if _spikeT0 then
            EC_spikePhase.vendor = EC_spikePhase.vendor + (EC_prof() - _spikeT0)
        end
    end
end)

EC_IsMerchantAllowed = function()
    -- Defensive fallback when DB hasn't loaded yet. Matches the v2.13.x
    -- EnsureDB default of "both" (All Merchants) so a missing-DB call here
    -- gives the same answer as a freshly-initialised DB.
    local mode = DB and DB.merchantMode or "both"
    -- v2.74.0: "goblin" and "any" only mean something where the Goblin
    -- Merchant companion exists - one requires it, the other excludes it.
    -- On a realm without it, collapse to "both" (All Merchants). Without
    -- this, a stored "goblin" would silently sell nothing at every vendor,
    -- with the dropdown that set it now hidden. Left as a runtime gate
    -- rather than a DB rewrite so the setting survives for realms that do
    -- have the pet.
    -- v2.75.0 SAFETY: peFeaturesActive (real PE presence), NOT peFeaturesVisible
    -- (which honours the /ec affixfallback UI preview). The layout preview must
    -- never widen merchant targeting on a live realm.
    if EC_compCache.peFeaturesActive and not EC_compCache.peFeaturesActive() then
        return true
    end
    if mode == "any" then
        -- "any": only normal merchants (not the Goblin Merchant pet).
        local targetName = UnitExists("target") and UnitName("target") or ""
        return targetName ~= TARGET_NAME
    elseif mode == "both" then
        -- "both" (default since v2.13.x): any merchant. Renamed in the
        -- dropdown to "All Merchants" for clarity.
        return true
    else
        -- "goblin": only the Goblin Merchant pet (was the default through
        -- v2.13.0; flipped to "both" in v2.13.x to support new players who
        -- haven't unlocked the pet yet).
        return UnitExists("target") and UnitName("target") == TARGET_NAME
    end
end

-- Mouse-over preview: counts what BuildQueue would sell right now. When no
-- merchant is targeted, fall back to the broadest case (merchantAllowed=true)
-- so the preview reflects the whitelist/quality threshold, not only greys.
local function EC_PreviewSellable()
    if not DB then
        return 0, 0
    end
    local merchantAllowed = true
    if UnitExists("target") then
        merchantAllowed = EC_IsMerchantAllowed()
    end
    local junkOnly = not merchantAllowed
    local count, copper = 0, 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local sellable, link, itemID, sellPrice, itemCount = EC_IsSellable(bag, slot, junkOnly)
            if sellable then
                count = count + (itemCount or 1)
                if sellPrice and sellPrice > 0 then
                    copper = copper + EC_GetItemPrice(link, itemID, sellPrice, itemCount)
                end
            end
        end
    end
    return count, copper
end
-- Exposed to split files. The minimap mouse-over tooltip (now in
-- EbonClearance_Minimap.lua post-Stage-8b) calls this for its
-- "Sellable now: N items" + "Est. value: ..." lines. Also reachable
-- by the LDB launcher's `OnTooltipShow`.
NS.PreviewSellable = EC_PreviewSellable

-- The Release-1 bag-display layer (sell-border tint helpers, the
-- NS.RefreshSellBorders body, the sellability-trace inspector that
-- drives /ec sellinfo and Alt+Shift+Right-Click, plus the
-- bagSlotFromButton helper) all live in EbonClearance_BagDisplay.lua
-- after Stage 6 of the file split. Every helper is attached to
-- EC_compCache (= NS.compCache, declared in Core), so call sites in
-- this file already resolve via the shared cache table and need no
-- changes. NS.RefreshSellBorders is forward-declared as a no-op stub
-- near the top of THIS file (so the Character Settings panel toggle
-- can call it before BagDisplay loads its real body).


local function StartRun()
    if not EC_IsAddonEnabledForChar() then
        return
    end
    EC_StampEvent("vendorRunStart")
    if EC_compCache.vendorRunning then
        return
    end

    local merchantAllowed = EC_IsMerchantAllowed()

    NS.HookDeletePopupOnce()

    EC_compCache.vendorRunning = true

    -- v2.46.4: fresh merchant cycle, fresh attempts. See declaration
    -- of EC_vendorRefusedThisRun above for the wedge bug this guards.
    wipe(EC_vendorRefusedThisRun)

    EC_RecordInventoryWorthSample()

    -- Auto-repair. v2.9.0 added the optional guild-bank branch: when
    -- DB.repairUseGuildBank is on AND the player is in a guild AND the
    -- guild bank can fund the full repair cost, RepairAllItems(1) charges
    -- the bank instead of personal gold. Any miss in the guild chain
    -- falls through to the existing personal-gold branch.
    if
        DB
        and DB.repairGear == true
        and CanMerchantRepair
        and CanMerchantRepair()
        and GetRepairAllCost
        and RepairAllItems
    then
        local repairCost, canRepair = GetRepairAllCost()
        if canRepair and repairCost and repairCost > 0 then
            local useGuild = DB.repairUseGuildBank == true
                and IsInGuild
                and IsInGuild()
                and CanGuildBankRepair
                and CanGuildBankRepair()
                and GetGuildBankWithdrawMoney
                and GetGuildBankWithdrawMoney() >= repairCost
            if useGuild then
                RepairAllItems(1) -- 1 = use guild bank funds
                -- v2.38.1: helpers write to DB + ADB.accountStats.
                EC_BumpStat("totalRepairs", 1)
                EC_BumpStat("totalRepairCopper", repairCost)
                EC_session.repairs = EC_session.repairs + 1
                EC_session.repairCopper = EC_session.repairCopper + repairCost
                PrintNicef(L["Repaired from guild bank: %s"], CopperToColoredText(repairCost))
            elseif GetMoney and GetMoney() >= repairCost then
                RepairAllItems()
                EC_BumpStat("totalRepairs", 1)
                EC_BumpStat("totalRepairCopper", repairCost)
                EC_session.repairs = EC_session.repairs + 1
                EC_session.repairCopper = EC_session.repairCopper + repairCost
            end
        end
    end

    BuildQueue(not merchantAllowed)

    if #queue == 0 then
        PrintNice(L["Nothing to sell."])
        EC_compCache.vendorRunning = false
        if UnitExists("target") and UnitName("target") == TARGET_NAME and MerchantFrame and MerchantFrame:IsShown() then
            EC_SummonGreedyWithDelay()
        end
        return
    end

    worker.t = 0
    worker:Show()
end

-- The tooltip annotation system (EC_AnnotateTooltip + EC_ClearTooltipFlag
-- + EC_InstallTooltipHookOnce) lives in EbonClearance_Tooltip.lua after
-- Stage 8c of the file split. Exposed as NS.InstallTooltipHookOnce for
-- the ADDON_LOADED branch in this file to call.


-- v2.16.0: Fast Loot BoP-bind auto-dismiss. When Fast Loot is on and the
-- user loots a Bind-on-Pickup item, Blizzard normally shows a LOOT_BIND
-- popup asking "are you sure?". That popup blocks the rest of the loot
-- queue draining and defeats the point of Fast Loot. This hook auto-
-- confirms each LootSlot call and force-hides the popup. Self-gates on
-- DB.fastLoot at call time so non-Fast-Loot users keep the Blizzard
-- safety prompt. Idempotent: the hookedOnce guard makes a second call
-- cheap if anything ever calls this twice. Pattern borrowed from
-- LootClicker (others/LootClicker-master/core.lua:158-161).
local EC_fastLootHooked = false
local function EC_InstallFastLootHookOnce()
    if EC_fastLootHooked then
        return
    end
    EC_fastLootHooked = true
    hooksecurefunc("LootSlot", function(slot)
        if not DB or not DB.fastLoot then
            return
        end
        ConfirmLootSlot(slot)
        StaticPopup_Hide("LOOT_BIND")
    end)
end




-- The list-row factories (EC_compCache.makeListRowFactory,
-- buildListHeaderRow, buildListSearchAndSortRow,
-- buildListScrollArea) live in EbonClearance_ListWidget.lua after
-- Stage 8e-ix-d of the file split. Hung off EC_compCache (not as
-- file-scope locals) to stay under Lua 5.1's 200-locals-per-main-chunk
-- cap.

-- ---------------------------------------------------------------------------
-- Panel-text principle (v2.20.2)
-- ---------------------------------------------------------------------------
-- Panel descriptions (yellow MakeLabel) and grey checkbox notes
-- (|cff888888...|r) should answer one of three questions for the
-- player:
--   1. What does this do?
--   2. When does it apply?
--   3. How do I override it?
-- If a sentence explains WHY a feature exists, cites version history,
-- or names an internal mechanism, cut it. The player doesn't care; we
-- have CLAUDE.md and source comments for that. Same lens applies when
-- adding a new toggle or panel description.


-- CreateListUI body lives in EbonClearance_ListWidget.lua after
-- Stage 8e-ix-d of the file split. Exposed as NS.CreateListUI for
-- split panel files that need to build a list widget.


-- The minimap button, LDB launcher, and combat-vendor button live in
-- EbonClearance_Minimap.lua after Stage 8b of the file split. Exposed
-- as NS.CreateMinimapButton, NS.CreateLDBLauncher,
-- NS.CreateTargetMerchantButton, NS.UpdateMinimapPos.


-- v2.13.3: removed the dormant vendor-button cluster (EC_vendorButton,
-- EC_CreateVendorButton, EC_SaveVendorButtonPos, EC_UpdateVendorButtonVisibility,
-- and the vendorBtn{X,Y,Point,RelPoint,Shown} DB fields). The cluster had
-- carried a luacheck:ignore suppression because no caller existed since
-- before v2.13.0. If a future opt-in vendor button is desired, build it
-- fresh on top of EC_CreateTargetMerchantButton (the existing combat-safe
-- SecureActionButton helper) rather than reviving this dead surface.

StaticPopupDialogs["EC_CONFIRM_RESET_LIFETIME"] = {
    text = L["Reset |cffb6ffb6EbonClearance|r lifetime stats?\n|cffaaaaaaThis clears money earned, items sold, items deleted, and repair totals. Session stats are not affected.|r"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_RESET_SESSION"] = {
    text = L["Reset session stats?"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.72.0: confirm popups triggered from inside the Interface Options
-- window can spawn UNDER it - the options frame is toplevel
-- (click-raises above same-strata siblings) and sits high enough that
-- FULLSCREEN_DIALOG was still not above it in the field. TOOLTIP is the
-- strata this codebase already uses for pop-outs that must beat the
-- settings window (NS.RaiseTooltipAboveWindows precedent). Raise while
-- shown and restore on hide - scoped per-show because Blizzard REUSES
-- the StaticPopup1..4 frames for its own dialogs; a permanent strata
-- change would leak onto those.
EC_compCache.popupRaiseOnShow = function(self)
    self._ecPrevStrata = self:GetFrameStrata()
    self:SetFrameStrata("TOOLTIP")
end
EC_compCache.popupRaiseOnHide = function(self)
    if self._ecPrevStrata then
        self:SetFrameStrata(self._ecPrevStrata)
        self._ecPrevStrata = nil
    end
end

StaticPopupDialogs["EC_CONFIRM_DELETE_PROFILE"] = {
    text = L['Delete profile "|cffffff00%s|r"?\n|cffaaaaaaThis cannot be undone.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    OnShow = EC_compCache.popupRaiseOnShow,
    OnHide = EC_compCache.popupRaiseOnHide,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.72.0: deleting a settings profile repoints every character that
-- used it back to Default, so spell that out in the prompt.
StaticPopupDialogs["EC_CONFIRM_DELETE_SPROFILE"] = {
    text = L['Delete settings profile "|cffffff00%s|r"?\n|cffaaaaaaCharacters using it switch to Default. This cannot be undone.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    OnShow = EC_compCache.popupRaiseOnShow,
    OnHide = EC_compCache.popupRaiseOnHide,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.75.0 (fresh-audit fix): saving over an existing same-name settings
-- profile used to overwrite it silently (delete had a confirm, save did not).
StaticPopupDialogs["EC_CONFIRM_OVERWRITE_SPROFILE"] = {
    text = L['Overwrite settings profile "|cffffff00%s|r"?\n|cffaaaaaaIts saved settings are replaced with this character\'s current ones. This cannot be undone.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    OnShow = EC_compCache.popupRaiseOnShow,
    OnHide = EC_compCache.popupRaiseOnHide,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_CLEAR_PROFILE"] = {
    text = L['Clear all items from profile "|cffffff00%s|r"?\n|cffaaaaaaThe profile itself will remain.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    OnShow = EC_compCache.popupRaiseOnShow,
    OnHide = EC_compCache.popupRaiseOnHide,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Generic confirmation for the per-list "Clear All" button on every list panel
-- (Whitelist - Character / Whitelist - Account / Blacklist / Deletion List).
-- The %s slot is filled with the list's user-facing title.
StaticPopupDialogs["EC_CONFIRM_CLEAR_LIST"] = {
    -- v2.76.0 (Serv report): names the count as well as the list. Knowing
    -- you are about to drop 327 entries is the thing that makes an
    -- irreversible confirmation worth reading.
    text = L['Remove all |cffffff00%s|r items from |cffffff00%s|r?\n|cffaaaaaaThis cannot be undone.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.42.0: confirm enabling auto-delete-on-pickup (irreversible behaviour).
StaticPopupDialogs["EC_CONFIRM_AUTODELETE"] = {
    text = L["Auto-delete permanently destroys Delete List items the instant they're looted - no vendor step, no undo. Turn it on?"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.12.0 stale-upgrade cleanup confirmation popup. The %d slot is filled
-- with the count of stale entries detected by /ec clean upgrades. The
-- OnAccept invokes the callback function passed via StaticPopup_Show's
-- third "data" argument, mirroring the EC_CONFIRM_CLEAR_LIST pattern.
-- v2.49.2: conflicting-addon warning popup. Shown once at PLAYER_LOGIN
-- when EC's delete path is active AND the detected conflicting addon is
-- loaded AND the player hasn't opted out. Modal so it can't be missed
-- (a one-time chat line was easy to scroll past). "Open Settings" jumps
-- to the main panel where the opt-out toggle lives.
-- EC-TRAP: this popup deliberately NAMES the conflicting addon ("Auto
-- Delete") - a user-sanctioned exception to the "No third-party addon
-- references in new EC artefacts" rule, granted because the detection is
-- folder-specific and naming it makes the warning actionable. The
-- exception is THIS STRING ONLY: the detection helper, all comments, and
-- the /ec bugreport line stay neutral. Do NOT propagate the name
-- elsewhere, and do NOT "neutralise" this string back.
StaticPopupDialogs["EC_CONFLICT_WARNING"] = {
    text = L["|cffff4444EbonClearance has detected that Auto Delete is also running.|r Only one bag-management addon should handle deletions at a time - running both can contest the delete-confirm popup and make items disappear unexpectedly. Turn off one of the two. You can silence this warning in EbonClearance settings."],
    button1 = L["Open Settings"],
    button2 = OKAY,
    OnAccept = function()
        NS.OpenOptionsPanel("EbonClearanceOptionsMain")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_CLEAN_UPGRADES"] = {
    text = L["Remove |cffffff00%d|r stale 'Upgrade'-tagged entries from your Keep List?\n|cffaaaaaaThese items were auto-tagged as upgrades but are no longer above your currently-equipped iLvl. Manual Keep List entries (no auto-tag) and 'Worn'-tagged entries are not affected.|r"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.12.0 first-run welcome popup. Fired once on PLAYER_LOGIN when EnsureDB
-- detected a fresh install (DB._needsWelcome). Two-button choice:
-- Keep Defaults (closes silently after a chat ack) or Open Settings (jumps
-- the Interface Options frame to the EbonClearance main panel). The double
-- InterfaceOptionsFrame_OpenToCategory call is a known 3.3.5a workaround
-- for the first-time-this-session focus quirk - the same pattern used by
-- the slash command's "open settings" fallback at the bottom of the file.
-- v2.38.0: confirmation popup for the Quickstart panel's Apply button.
-- The text() callback fills the preset name (or "your tailored answers")
-- via the dialog's `data` arg captured at StaticPopup_Show time. OnAccept
-- reads data.answers / data.fixedCaps / data.presetKey and calls
-- NS.Quickstart.Apply. The popup is settings-only - the body text spells
-- this out so a player who applies a preset can't be surprised about
-- Sell / Keep / Delete lists.
StaticPopupDialogs["EC_APPLY_QUICKSTART"] = {
    text = L["Apply %s?\n\nThis changes your speed, protection, auto-sell, and visual settings.\n\nYour |cffb6ffb6Sell|r, |cffb6ffb6Keep|r, and |cffb6ffb6Delete|r lists stay exactly as they are."],
    button1 = "Apply",
    button2 = CANCEL,
    OnAccept = function(self, data)
        if data and NS.Quickstart and NS.Quickstart.Apply then
            NS.Quickstart.Apply(data.answers, data.fixedCaps, data.presetKey)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Build the static widgets for the main options panel. Called once per panel
-- (guarded by `panel.inited` in OnShow). `refreshStats` is the dynamic refresh
-- callback captured by the Reset button.


InterfaceOptions_AddCategory(_G["EbonClearanceOptionsMain"])
-- v2.38.0: Quickstart is intentionally NOT registered as an Interface
-- Options sub-panel - it's a standalone modal frame parented to UIParent.
-- The only entry points are the "Open Quickstart" button on the Main
-- panel and the fresh-install PLAYER_LOGIN auto-open. Keeps the sidebar
-- focused on the long-form settings panels.


-- CreateListUI, the 5 list-row factories, and EC_AddScanByQualityRow live in
-- EbonClearance_ListWidget.lua after Stage 8e-ix-d of the file split. Exposed
-- as NS.CreateListUI and NS.AddScanByQualityRow for split panel files.


-- ============================================================
-- Whitelist Profiles Panel



InterfaceOptions_AddCategory(_G["EbonClearanceOptionsMerchant"]) -- Merchant Settings
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsScavenger"]) -- Scavenger Settings
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsCharacter"]) -- Item Highlighting
-- v2.36.x: Stats sub-panel registered between the main settings group
-- (Merchant / Protection / Scavenger / Highlighting) and the list group
-- (Sell / Account Sell / Keep / Delete) so the player sees configuration
-- panels first, then their stats dashboard, then the curated lists. The
-- Stats panel file itself does not call InterfaceOptions_AddCategory; the
-- sort position is controlled at one place here.
-- v2.39.x: Guild panel loads before Events.lua (see .toc), so it is also
-- registered here, immediately after Stats - Personal, to keep both stats
-- panels adjacent above Sell List.
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsStats"]) -- Stats - Personal
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsGuild"]) -- Stats - Guild
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsServer"]) -- Stats - Server (v2.58.0)
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsWhitelist"]) -- Sell List
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsAccountWhitelist"]) -- Account Sell List
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsBlacklist"]) -- Keep List
-- v2.49.3: Keep Settings (internal frame name EbonClearanceOptionsBlacklistSettings,
-- formerly labelled "Protection Settings") sits right under Keep List so it mirrors
-- Delete List + Delete Settings. Frame name kept for compat with help-link pointers.
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsBlacklistSettings"]) -- Keep Settings
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsDeletion"]) -- Delete List
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsDeletionSettings"]) -- Delete Settings
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsProcessBags"]) -- Process Bags
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsProfiles"]) -- Profiles
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsSettingsProfiles"]) -- Settings Profiles (v2.72.0)
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsImportExport"]) -- Import/Export

-- v2.11.0 reactive panel layout. The Interface Options frame is user-
-- resizable in some UI mod packs (and the resize handle is exposed as a
-- draggable widget on PE-ElvUI). Pre-v2.11.0 the addon's panels stayed
-- clamped at their build-time width because every label, scroll-content,
-- and list-row width was a snapshot of EC_PANEL_WIDTH taken at first
-- OnShow. Hooking the container's OnSizeChanged once routes every
-- registered widget through EC_compCache.refreshLayouts on each resize -
-- labels re-wrap, scroll content re-fits, list frames already track via
-- BOTTOMRIGHT anchors (their visible drift was just label clutter on
-- top, fixed by the same width refresh).
if InterfaceOptionsFramePanelContainer and InterfaceOptionsFramePanelContainer.HookScript then
    InterfaceOptionsFramePanelContainer:HookScript("OnSizeChanged", function()
        EC_compCache.refreshLayouts()
    end)
end

-- The bug-report diagnostic snapshot (EC_CopperToPlainText,
-- EC_BuildBugReport, EC_ShowBugReport) lives in
-- EbonClearance_BugReport.lua after Stage 8 of the file split.
-- Exposed as NS.ShowBugReport for the button on the main settings panel.


-- Conflict detection + resolution across whitelist/blacklist/deleteList.
-- Precedence when auto-resolving: blacklist > deleteList > whitelist.
-- Keybinding registration. Populates the "EbonClearance" section of
-- ESC -> Key Bindings. Four bindings:
--   - "Target Goblin Merchant" - dispatched through the hidden
--     EbonClearanceTargetMerchantButton SecureActionButton so it works in
--     combat lockdown.
--   - Three operational bindings (open/close settings, toggle enabled,
--     force sell at current merchant) declared in Bindings.xml and wired
--     to the EbonClearance_* global handlers further down this file.
BINDING_HEADER_EBONCLEARANCE = "EbonClearance"
_G["BINDING_NAME_CLICK EbonClearanceTargetMerchantButton:LeftButton"] = "Target Goblin Merchant"
-- Secure click bindings show their raw "CLICK <button>:<mouseButton>" action
-- string in the keybind UI unless a BINDING_NAME_ global gives them a label.
_G["BINDING_NAME_CLICK EbonClearanceProcessCastBtn:LeftButton"] = "Process Next"
BINDING_NAME_EBONCLEARANCE_TOGGLE_SETTINGS = "Open/close settings"
BINDING_NAME_EBONCLEARANCE_TOGGLE_ENABLED = "Toggle enabled"
BINDING_NAME_EBONCLEARANCE_FORCE_SELL = "Force sell at current merchant"
BINDING_NAME_EBONCLEARANCE_TOGGLE_LOOTLOG = "Open/close Loot Log"
-- Cross-list intent groups for the add-time conflict guard:
--   keep   = whitelist (per-character) + accountWhitelist (account-wide)
--   sell   = blacklist
--   delete = deleteList
-- Same-intent scopes are NOT in conflict (whitelist + accountWhitelist is
-- redundant, not contradictory). Cross-intent IS the conflict we refuse at
-- input time. The post-hoc EC_ApplyCleanResolution below remains as the
-- legacy-data safety net for DBs that pre-date this guard.
--
-- Returns the name of an already-occupying list with a different intent,
-- or nil when the add is safe. Forward-declared at the top of the file so
-- EC_AddItemToList can call it before this body is reached.
EC_FindAddConflict = function(itemID, targetListName)
    if not itemID or not targetListName then
        return nil
    end
    local function intentOf(n)
        if n == "whitelist" or n == "accountWhitelist" then
            return "keep"
        end
        if n == "blacklist" then
            return "sell"
        end
        if n == "deleteList" then
            return "delete"
        end
        return nil
    end
    local targetIntent = intentOf(targetListName)
    if not targetIntent then
        return nil
    end
    local checks = {
        { name = "blacklist", data = DB and DB.blacklist },
        { name = "deleteList", data = DB and DB.deleteList },
        { name = "whitelist", data = DB and DB.whitelist },
        { name = "accountWhitelist", data = ADB and ADB.whitelist },
    }
    for i = 1, #checks do
        local c = checks[i]
        if c.name ~= targetListName and c.data and c.data[itemID] and intentOf(c.name) ~= targetIntent then
            return c.name
        end
    end
    return nil
end
-- Exposed to split files. Stage 8d uses NS.FindAddConflict from the bag
-- context menu's row-click conflict guard (refuses the add at click time
-- when the item is already on a different-intent list).
NS.FindAddConflict = EC_FindAddConflict

local function EC_ScanListConflicts()
    local lists = {
        { name = "whitelist", data = DB.whitelist },
        { name = "blacklist", data = DB.blacklist },
        { name = "deleteList", data = DB.deleteList },
    }
    local where = {}
    for i = 1, #lists do
        local e = lists[i]
        if type(e.data) == "table" then
            for id in pairs(e.data) do
                if type(id) == "number" then
                    where[id] = where[id] or {}
                    where[id][#where[id] + 1] = e.name
                end
            end
        end
    end
    local conflicts = {}
    for id, names in pairs(where) do
        if #names >= 2 then
            conflicts[#conflicts + 1] = { id = id, lists = names }
        end
    end
    table.sort(conflicts, function(a, b)
        return a.id < b.id
    end)
    return conflicts
end

local function EC_PrintConflictReport(conflicts)
    if #conflicts == 0 then
        PrintNice(L["|cff00ff00No list conflicts found.|r"])
        return
    end
    PrintNicef(L["Found |cffffff00%d|r item(s) present in multiple lists:"], #conflicts)
    for i = 1, #conflicts do
        local c = conflicts[i]
        local name = GetItemInfo(c.id) or ("ItemID:" .. c.id)
        PrintNicef(L["  |cffb6ffb6%d|r  %s  [%s]"], c.id, name, table.concat(c.lists, ", "))
    end
end

local function EC_ApplyCleanResolution(conflicts)
    local removed = 0
    for i = 1, #conflicts do
        local c = conflicts[i]
        local inBL, inDel, inWL = false, false, false
        for j = 1, #c.lists do
            local n = c.lists[j]
            if n == "blacklist" then
                inBL = true
            elseif n == "deleteList" then
                inDel = true
            elseif n == "whitelist" then
                inWL = true
            end
        end
        if inBL and inWL then
            DB.whitelist[c.id] = nil
            removed = removed + 1
        end
        if inBL and inDel then
            DB.deleteList[c.id] = nil
            removed = removed + 1
        end
        if inDel and inWL then
            DB.whitelist[c.id] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- v2.12.0 stale-upgrade scanner. Walks DB.blacklistAuto entries with the
-- "upgrade" tag and re-evaluates each against the player's currently-
-- equipped gear. Returns three lists:
--   stale    - entries that are no longer upgrades (iLvl <= lowest equipped)
--   deferred - entries we couldn't evaluate (GetItemInfo not loaded yet)
--   skipped  - entries we can't evaluate (no equipLoc / all candidate slots
--              empty / equipLoc not in INVTYPE_SLOTS); these stay put
-- Mirror of EC_compCache.checkBagsForUpgrades' eligibility logic, inverted.
-- Hung off EC_compCache to avoid burning two main-chunk local slots
-- (Lua 5.1 caps that at 200 and we sit near it).
function EC_compCache.buildStaleUpgradeReport()
    local stale, deferred, skipped = {}, {}, {}
    if not DB or type(DB.blacklistAuto) ~= "table" then
        return { stale = stale, deferred = deferred, skipped = skipped }
    end
    for id, tag in pairs(DB.blacklistAuto) do
        if tag == "upgrade" and DB.blacklist and DB.blacklist[id] then
            local name, _, _, iLvl, _, _, _, _, equipLoc = GetItemInfo(id)
            if not name or not iLvl then
                deferred[#deferred + 1] = id
            else
                local slots = equipLoc and equipLoc ~= "" and EC_compCache.INVTYPE_SLOTS[equipLoc]
                if not slots then
                    skipped[#skipped + 1] = { id = id, name = name }
                else
                    local lowestEquipped = EC_compCache.getLowestEquippedILvl(slots)
                    if not lowestEquipped then
                        skipped[#skipped + 1] = { id = id, name = name }
                    elseif iLvl <= lowestEquipped then
                        stale[#stale + 1] = { id = id, name = name, iLvl = iLvl, lowestEquipped = lowestEquipped }
                    end
                end
            end
        end
    end
    return { stale = stale, deferred = deferred, skipped = skipped }
end

-- Removes the entries flagged as stale by buildStaleUpgradeReport.
-- Pulls them out of both DB.blacklist and DB.blacklistAuto so the tooltip
-- annotation and EC_IsSellable both stop treating them as protected.
-- Returns the count of removed entries.
function EC_compCache.applyStaleUpgradeCleanup(report)
    if not report or not report.stale then
        return 0
    end
    local removed = 0
    for i = 1, #report.stale do
        local id = report.stale[i].id
        if DB.blacklist and DB.blacklist[id] then
            DB.blacklist[id] = nil
        end
        if DB.blacklistAuto and DB.blacklistAuto[id] then
            DB.blacklistAuto[id] = nil
        end
        removed = removed + 1
    end
    return removed
end

-- Handlers for the three operational keybindings (declared in Bindings.xml,
-- labels above with the binding registration block).
function EbonClearance_ToggleSettings()
    if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then
        InterfaceOptionsFrame:Hide()
    else
        NS.OpenOptionsPanel("EbonClearanceOptionsMain")
    end
end

function EbonClearance_ToggleLootLog()
    EnsureDB()
    if NS.ToggleLootWindow then
        NS.ToggleLootWindow()
    end
end

function EbonClearance_ToggleEnabled()
    EnsureDB()
    DB.enabled = not DB.enabled
    PrintNicef(L["Now %s."], DB.enabled and L["|cff00ff00enabled|r"] or L["|cffff4444disabled|r"])
    PlaySound(DB.enabled and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
    -- v2.39.1: single source of truth for the master Enable state.
    -- The helper now refreshes every UI surface that mirrors
    -- DB.enabled so a flip via ANY entry point (minimap right-click,
    -- Main panel checkbox, /ec enable / disable, keybind, LDB
    -- launcher) keeps every other surface in sync. Without this,
    -- toggling via the panel left the minimap icon stuck saturated
    -- (and vice versa) - bug found right after v2.39.1 wired the
    -- panel checkbox.
    local mb = _G["EbonClearanceMinimapButton"]
    if mb and mb.icon and mb.icon.SetDesaturated then
        mb.icon:SetDesaturated(not DB.enabled)
    end
    local mp = _G["EbonClearanceOptionsMain"]
    if mp and mp.enableCB then
        mp.enableCB:SetChecked(DB.enabled ~= false)
    end
end

function EbonClearance_ForceSell()
    EnsureDB()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        PrintNice(L["|cffff4444Force sell|r: open a merchant first."])
        return
    end
    StartRun()
end

-- v2.49.1: dump the chance-on-hit autolearn state into a copyable window.
-- Three sections: author-vetted (in-code EC_CHANCE_PROC_CONFIRMED_ITEMS),
-- autolearned (ADB.chanceProcConfirmedItems), and ambiguous events
-- (ADB.chanceProcAmbiguous). Read-only.
function NS.ShowAutolearnPeek()
    EnsureAccountDB()
    local lines = {}
    lines[#lines + 1] = "=== EbonClearance /ec autolearnpeek ==="
    lines[#lines + 1] = "Author-vetted (in-code EC_CHANCE_PROC_CONFIRMED_ITEMS):"
    local authored = NS.chanceProcConfirmedItems or {}
    local authoredKeys = {}
    for k in pairs(authored) do
        authoredKeys[#authoredKeys + 1] = k
    end
    table.sort(authoredKeys)
    if #authoredKeys == 0 then
        lines[#lines + 1] = "  (none)"
    else
        for _, id in ipairs(authoredKeys) do
            local rec = authored[id]
            lines[#lines + 1] = string.format(
                "  [%d] %s -> %s (spellID %d)",
                id, tostring(rec.item), tostring(rec.family), rec.spellID
            )
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Autolearned (ADB.chanceProcConfirmedItems):"
    local learned = ADB.chanceProcConfirmedItems or {}
    local learnedKeys = {}
    for k in pairs(learned) do
        learnedKeys[#learnedKeys + 1] = k
    end
    table.sort(learnedKeys)
    if #learnedKeys == 0 then
        lines[#lines + 1] = "  (none)"
    else
        for _, id in ipairs(learnedKeys) do
            local rec = learned[id]
            lines[#lines + 1] = string.format(
                "  [%d] %s -> %s (spellID %d, learnedAt %.1f)",
                id, tostring(rec.item), tostring(rec.family), rec.spellID, rec.learnedAt or 0
            )
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Ambiguous events (ADB.chanceProcAmbiguous):"
    local amb = ADB.chanceProcAmbiguous or {}
    if #amb == 0 then
        lines[#lines + 1] = "  (none)"
    else
        for i, ev in ipairs(amb) do
            lines[#lines + 1] = string.format(
                "  #%d: spellID %d (%s) @ %.1f, source=%s, %d candidate(s)",
                i, ev.spellID or 0, tostring(ev.family), ev.timestamp or 0,
                tostring(ev.source), #(ev.candidates or {})
            )
            for _, c in ipairs(ev.candidates or {}) do
                lines[#lines + 1] = string.format(
                    "    [%d] %s (procLine: %s)",
                    c.itemID or 0, tostring(c.itemName), tostring(c.procLine)
                )
            end
        end
    end
    -- Reuse EC_ShowCopyFrame from EbonClearance_BugReport.lua, exposed as
    -- NS.ShowCopyFrame in v2.49.1 so out-of-file callers can render a
    -- copyable state dump instead of flooding chat. Same helper backs
    -- /ec captureproc, /ec affixdebug dump, /ec processdebug, etc.
    -- Signature: (titleText, bodyText, chatHint). Fall back to a chat
    -- dump only if BugReport.lua didn't load (defensive).
    local body = table.concat(lines, "\n")
    if NS.ShowCopyFrame then
        NS.ShowCopyFrame("EbonClearance /ec autolearnpeek", body)
    else
        PrintNice(body)
    end
end

SLASH_EBONCLEARANCE1 = "/ec"
SlashCmdList["EBONCLEARANCE"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        NS.OpenOptionsPanel("EbonClearanceOptionsMain")
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)")
    cmd = (cmd or ""):lower()
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if cmd == "affixfind" then
        local needle = rest:lower()
        if needle == "" then
            PrintNice(L["usage: /ec affixfind <text>"])
            return
        end
        local set = EC_compCache.knownAffixDescriptions or {}
        local hits = 0
        for k in pairs(set) do
            if k:lower():find(needle, 1, true) then
                hits = hits + 1
                PrintNicef("  [%s]", k)
            end
        end
        PrintNicef("affixfind: %d match(es)", hits)
        return
    elseif cmd == "affixdump" then
        -- v2.23.0 debug: re-runs the known-affix spellbook scan, then
        -- prints diagnostic info for tracking down dupe-gate misfires.
        -- Intended as a one-shot inspector; safe to leave in but not
        -- documented in /ec help.
        if EC_compCache.refreshKnownAffixes then
            EC_compCache.refreshKnownAffixes()
        end
        local set = EC_compCache.knownAffixDescriptions or {}
        local count = 0
        local sample = {}
        for k in pairs(set) do
            count = count + 1
            if #sample < 5 then
                sample[#sample + 1] = k
            end
        end
        PrintNicef("affixdump: %d known descriptions in set", count)
        for _, s in ipairs(sample) do
            PrintNicef("  - [%s]", s)
        end
        -- Scan bags for the first affixed item and dump its data.
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    local affix = EC_compCache.bagSlotAffixData(bag, slot)
                    if affix then
                        PrintNicef(
                            "bag (%d,%d) %s: name=[%s] rank=[%s] desc=[%s]",
                            bag,
                            slot,
                            link,
                            tostring(affix.name),
                            tostring(affix.rank),
                            tostring(affix.description)
                        )
                        local norm = EC_compCache.normaliseAffixDesc(affix.description)
                        PrintNicef("  norm=[%s]", tostring(norm))
                        PrintNicef("  match? %s", tostring(EC_compCache.playerHasAffixDescription(affix.description)))
                        return
                    end
                end
            end
        end
        PrintNice("affixdump: no affixed bag items found")
        return
    elseif cmd == "procdump" then
        -- v2.26.0 debug: dump the per-link affix lookup for the first
        -- Chance-on-hit bag item, plus the HasRandomProperty gate
        -- result and a hyperlink-tooltip-line dump so we can see what
        -- SetHyperlink(link) renders. Use this when the chance-on-hit
        -- dupe gate misfires (item stays "Protected" when the player
        -- expects "Allowed").
        local svc = _G.ExtractionService
        local catalogSize = (svc and type(svc.learnedAffixes) == "table") and #svc.learnedAffixes or 0
        PrintNicef("procdump: ExtractionService.learnedAffixes has %d records", catalogSize)
        local learnedProcs = 0
        if svc and type(svc.learnedAffixes) == "table" then
            for _, r in ipairs(svc.learnedAffixes) do
                if r and r.learned and r.weaponOnly then
                    learnedProcs = learnedProcs + 1
                end
            end
        end
        PrintNicef("procdump: %d learned weaponOnly procs in catalog", learnedProcs)
        local allowedCount = 0
        for _ in pairs(ADB and ADB.allowedItems or {}) do
            allowedCount = allowedCount + 1
        end
        PrintNicef("procdump: %d Allowed Proc itemIDs (account-wide)", allowedCount)
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                local itemID = GetContainerItemID(bag, slot)
                if link and itemID and EC_compCache.itemHasChanceOnHit(bag, slot, itemID) then
                    PrintNicef("procdump: scanning (%d,%d) %s", bag, slot, link)
                    local hrp = HasRandomProperty and HasRandomProperty(link)
                    PrintNicef("  HasRandomProperty=%s", tostring(hrp))
                    local rec = EC_compCache.findLearnedAffixForItem and EC_compCache.findLearnedAffixForItem(link)
                    if rec then
                        PrintNicef(
                            "  match: name=[%s] id=%s learned=%s weaponOnly=%s",
                            tostring(rec.name),
                            tostring(rec.id),
                            tostring(rec.learned),
                            tostring(rec.weaponOnly)
                        )
                    else
                        PrintNice("  match: nil (no learnedAffixes name matched the tooltip)")
                    end
                    -- Dump the SetHyperlink tooltip lines so we can see
                    -- what text was searched.
                    EC_scanTooltip:ClearLines()
                    EC_scanTooltip:SetHyperlink(link)
                    for i = 1, EC_scanTooltip:NumLines() do
                        local fs = EC_compCache.scanLines[i]
                        if fs and fs.GetText then
                            local txt = fs:GetText()
                            if txt then
                                PrintNicef("  L%d: %s", i, txt)
                            end
                        end
                    end
                    return
                end
            end
        end
        PrintNice("procdump: no Chance-on-hit bag items found")
        return
    elseif cmd == "profile" or cmd == "profiles" then
        local sub, arg = rest:match("^(%S+)%s*(.*)")
        sub = (sub or ""):lower()
        arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")

        if sub == "save" and arg ~= "" then
            EnsureDB()
            -- Discard the boolean ok flag; PrintNice surfaces the failure
            -- message itself for the user. Renamed local from `msg` to
            -- `result` to avoid shadowing the outer slash-input `msg`.
            local _, result = EC_SaveProfile(arg)
            PrintNice(result)
        elseif sub == "load" and arg ~= "" then
            EnsureDB()
            local _, result = EC_LoadProfile(arg)
            PrintNice(result)
        elseif sub == "delete" and arg ~= "" then
            EnsureDB()
            local _, result = EC_DeleteProfile(arg)
            PrintNice(result)
        elseif sub == "list" or sub == "" then
            EnsureDB()
            PrintNice(L["Sell List Profiles:"])
            local names = {}
            for name in pairs(DB.whitelistProfiles) do
                if type(name) == "string" then
                    names[#names + 1] = name
                end
            end
            table.sort(names, function(a, b)
                return a:lower() < b:lower()
            end)
            for i = 1, #names do
                local wlCount = EC_CountItems(DB.whitelistProfiles[names[i]])
                local blCount = DB.blacklistProfiles[names[i]] and EC_CountItems(DB.blacklistProfiles[names[i]]) or 0
                local tag = (names[i] == DB.activeProfileName) and L[" |cff00ff00(active)|r"] or ""
                PrintNicef(L["  |cffffff00%s|r - %d whitelist, %d blacklist%s"], names[i], wlCount, blCount, tag)
            end
        else
            PrintNice(L["Usage: /ec profile save|load|delete|list <name>"])
        end
        return
    elseif cmd == "sprofile" or cmd == "sprofiles" then
        -- v2.72.0 settings profiles (selling behaviour per character).
        local sub, arg = rest:match("^(%S+)%s*(.*)")
        sub = (sub or ""):lower()
        arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")

        if sub == "save" and arg ~= "" then
            EnsureDB()
            local _, result = NS.SaveSettingsProfile(arg)
            PrintNice(result)
        elseif sub == "use" and arg ~= "" then
            EnsureDB()
            local _, result = NS.UseSettingsProfile(arg)
            PrintNice(result)
        elseif sub == "delete" and arg ~= "" then
            EnsureDB()
            local _, result = NS.DeleteSettingsProfile(arg)
            PrintNice(result)
        elseif sub == "list" or sub == "" then
            EnsureDB()
            PrintNice(L["Settings Profiles:"])
            local profiles = EbonClearanceDB.settingsProfiles or {}
            local names = {}
            for name in pairs(profiles) do
                if type(name) == "string" then
                    names[#names + 1] = name
                end
            end
            table.sort(names, function(a, b)
                return a:lower() < b:lower()
            end)
            local chars = EbonClearanceDB.chars or {}
            for i = 1, #names do
                local users = 0
                for _, charNS in pairs(chars) do
                    if (charNS.activeSettingsProfile or "Default") == names[i] then
                        users = users + 1
                    end
                end
                local tag = (names[i] == (DB.activeSettingsProfile or "Default")) and L[" |cff00ff00(this character)|r"]
                    or ""
                PrintNicef(L["  |cffffff00%s|r - used by %d character(s)%s"], names[i], users, tag)
            end
        else
            PrintNice(L["Usage: /ec sprofile save|use|delete|list <name>"])
        end
        return
    end

    if cmd == "bugreport" then
        NS.ShowBugReport()
        return
    end

    if cmd == "commtest" then
        -- v2.39.0: solo diagnostic for the version-alert comms layer.
        -- Tests wire relay (guild echo) and the nudge logic (simulated peer).
        if NS.Comms then
            NS.Comms.RunSelfTest()
        else
            PrintNice(L["|cffff4444Comms module not loaded.|r"])
        end
        return
    end

    if cmd == "guildtest" then
        -- Solo diagnostic for the guild-share panel: inject simulated members.
        if NS.GuildShare then
            local n = NS.GuildShare.InjectTestPeers()
            PrintNicef(L["Injected %d simulated guild members. Open the Guild panel (or re-run this with it open) to see the pooled data."], n)
        else
            PrintNice(L["|cffff4444Guild-share module not loaded.|r"])
        end
        return
    end

    if cmd == "procsharetest" then
        -- v2.53.0: solo diagnostic for the proc-share pipeline. Merges
        -- three high-range fake pairings into ADB.chanceProcConfirmedItems
        -- through the real ProcShare.mergeReply path. Confirms the merge
        -- writes work and populates NS.recentProcShareMerges so the new
        -- /ec bugreport section can be exercised without a live guildmate.
        if NS.ProcShare then
            local n = NS.ProcShare.InjectTestPeers()
            PrintNicef(L["Injected %d simulated proc pairing(s) into ADB.chanceProcConfirmedItems. Run /ec bugreport to see the merge ring."], n)
        else
            PrintNice(L["|cffff4444ProcShare module not loaded.|r"])
        end
        return
    end

    if cmd == "servertest" then
        -- v2.58.0: solo diagnostic for the Server Stats odometer. Injects fake
        -- realm sharers (including a spoofed one the sanity cap must drop) so
        -- the panel + live user-count can be exercised on one account.
        if NS.ServerShare then
            local n = NS.ServerShare.InjectTestPeers()
            PrintNicef(L["Injected %d simulated realm sharer(s). Open the Server panel to see the odometer (the spoofed one should be ignored)."], n)
        else
            PrintNice(L["|cffff4444Server-share module not loaded.|r"])
        end
        return
    end

    if cmd == "realmtest" then
        -- v2.58.0: solo diagnostic for the realm channel transport. Chat
        -- channels echo your own messages, so this verifies join/hide/send/
        -- receive with no second player.
        if NS.RealmComms then
            NS.RealmComms.RunSelfTest()
        else
            PrintNice(L["|cffff4444Realm comms module not loaded.|r"])
        end
        return
    end

    if cmd == "status" or cmd == "enable" or cmd == "disable" then
        -- v2.39.1: discoverable surface for the master Enable toggle.
        -- Pre-v2.39.1 the only ways to flip DB.enabled were the
        -- minimap right-click (subtle) or a keybind (only fires if
        -- bound). A real player report (Paladin, v2.39.0) showed up
        -- with `Enabled: false` in their bug report and "the addon
        -- stopped working" because they had no idea they'd disabled
        -- it. These three subcommands give a slash-driven recovery
        -- path that complements the new Main panel checkbox.
        EnsureDB()
        local currentlyEnabled = DB and DB.enabled ~= false
        if cmd == "status" then
            PrintNicef(
                L["Currently %s."],
                currentlyEnabled and L["|cff00ff00ENABLED|r"] or L["|cffff4444DISABLED|r"]
            )
            PrintNice(L["|cff888888Right-click the minimap icon, tick the Main panel checkbox, or type /ec enable / /ec disable to switch.|r"])
        elseif cmd == "enable" then
            if currentlyEnabled then
                PrintNice(L["Already enabled."])
            else
                EbonClearance_ToggleEnabled()
            end
        elseif cmd == "disable" then
            if not currentlyEnabled then
                PrintNice(L["Already disabled."])
            else
                EbonClearance_ToggleEnabled()
            end
        end
        -- v2.39.1: no need to re-sync UI surfaces here -
        -- EbonClearance_ToggleEnabled() does that for every entry
        -- point. The status-only branch above also doesn't flip
        -- state, so nothing to sync there either.
        return
    end

    if cmd == "locale" or cmd == "lang" or cmd == "language" then
        -- v2.43.1: force a UI language regardless of the client. On 3.3.5a a
        -- private-server client can only run a language whose data is
        -- installed, so this lets a player on an enUS client read EC in
        -- French / German (and lets the author preview translations).
        EnsureDB()
        local client = (NS.GetClientLocale and NS.GetClientLocale()) or "enUS"
        local registered = (NS.GetRegisteredLocales and NS.GetRegisteredLocales()) or {}
        local listText = (#registered > 0) and table.concat(registered, ", ") or "enUS"
        local want = rest:lower()
        if want == "" then
            local active = (NS.GetActiveLocale and NS.GetActiveLocale()) or client
            PrintNicef(L["Language: %s (your client is %s)."], active, client)
            PrintNicef(L["Change with /ec locale <code> (%s), or /ec locale auto to follow your client."], listText)
            return
        end
        if want == "auto" then
            EbonClearanceDB.localeOverride = false
            NS.SetLocaleOverride(false)
            PrintNicef(L["Now following your client language (%s). Type /reload to apply fully."], client)
            return
        end
        -- Resolve case-insensitively to a canonical code (codes are mixed-case).
        local canon
        if want == "enus" then
            canon = "enUS"
        end
        for _, code in ipairs(registered) do
            if code:lower() == want then
                canon = code
            end
        end
        if not canon then
            PrintNicef(L["Unknown language '%s'. Try auto, enUS, or one of: %s."], rest, listText)
            return
        end
        EbonClearanceDB.localeOverride = canon
        NS.SetLocaleOverride(canon)
        PrintNicef(L["Language set to %s. Type /reload to apply fully."], canon)
        return
    end

    if cmd == "affixdebug" then
        -- v2.37.0 (Borrow A): toggle / inspect / clear the affix-pipeline
        -- event log. The log is account-wide (ADB.affixDebug) so the
        -- enable flag survives /reload. Sub-actions:
        --   /ec affixdebug on      - start recording
        --   /ec affixdebug off     - stop recording
        --   /ec affixdebug status  - show current state + row count
        --   /ec affixdebug dump    - open a window with the plain-text event log
        --   /ec affixdebug clear   - wipe the recorded rows
        local sub = (rest:match("^(%S+)") or ""):lower()
        if not ADB then
            PrintNice(L["|cffff4444Affix debug requires the account DB; try again after the addon finishes loading.|r"])
            return
        end
        if sub == "on" then
            ADB.affixDebugEnabled = true
            PrintNice(L["|cffb6ffb6Affix debug: ON.|r Reproduce the issue, then run |cffffff00/ec affixdebug dump|r."])
        elseif sub == "off" then
            ADB.affixDebugEnabled = false
            PrintNice(L["|cffb6ffb6Affix debug: OFF.|r"])
        elseif sub == "clear" then
            ADB.affixDebug = nil
            PrintNice(L["|cffb6ffb6Affix debug log cleared.|r"])
        elseif sub == "status" or sub == "" then
            local rows = (ADB.affixDebug and ADB.affixDebug.rows) or {}
            PrintNicef(
                L["Affix debug: %s, %d row(s) recorded."],
                ADB.affixDebugEnabled and L["|cffb6ffb6ON|r"] or L["|cff888888off|r"],
                #rows
            )
            PrintNice(L["|cffaaaaaaSub-commands: on | off | status | dump | clear|r"])
        elseif sub == "dump" then
            if NS.ShowAffixDebugDump then
                NS.ShowAffixDebugDump()
            else
                PrintNice(L["|cffff4444Affix debug dump window is unavailable.|r"])
            end
        else
            PrintNicef(L["|cffff4444Unknown sub-command:|r %s. Try on / off / status / dump / clear."], sub)
        end
        return
    end

    if cmd == "rules" then
        -- v2.44.0: rule-summary copy frame. Plain-English breakdown
        -- of every active toggle + the precedence order EC uses.
        -- Same surface as the Main panel's "Current Rules" button.
        if NS.ShowRuleSummary then
            NS.ShowRuleSummary()
        else
            PrintNice("|cffff4444Rule summary is unavailable.|r")
        end
        return
    end

    if cmd == "minimap" then
        -- v2.44.7: show / hide / reset the EC minimap button.
        -- Workaround for clashes with minimap-replacement / magnifier
        -- addons (Magnify-WotLK clash reported by Safra).
        local sub = string.lower(rest or "")
        if sub == "on" or sub == "show" then
            if NS.SetMinimapButtonVisible then
                NS.SetMinimapButtonVisible(true)
            end
            PrintNice(L["|cffb6ffb6Minimap button shown.|r"])
        elseif sub == "off" or sub == "hide" then
            if NS.SetMinimapButtonVisible then
                NS.SetMinimapButtonVisible(false)
            end
            PrintNice(L["|cffffb84dMinimap button hidden. Use /ec, the LDB launcher, or your keybinding.|r"])
        elseif sub == "reset" then
            DB.minimapButtonAngle = 220
            if NS.UpdateMinimapPos then
                NS.UpdateMinimapPos()
            end
            PrintNice(L["|cffb6ffb6Minimap button position reset.|r"])
        else
            local state = (DB.minimapButton ~= false) and L["shown"] or L["hidden"]
            PrintNicef(L["Minimap button is currently |cffffff00%s|r."], state)
            PrintNice(L["Usage: /ec minimap on||off||reset"])
        end
        return
    end

    if cmd == "scandebug" then
        -- v2.44.12: scan-tooltip diagnostic. Dumps every TextLeft line
        -- of the hidden EbonClearanceScanTooltip after SetBagItem on
        -- the given bag slot, plus the parsed detection-helper outputs.
        -- Use when an item silently sells despite seeming to have an
        -- affix or proc - reveals whether the proc/affix text is in
        -- the scan tooltip at all, or whether PE's enrichment skips
        -- hidden tooltips (the leading hypothesis for Zukii's report).
        -- Usage: /ec scandebug <bag> <slot>
        local bagS, slotS = rest:match("^(%S+)%s+(%S+)")
        local bag = tonumber(bagS)
        local slot = tonumber(slotS)
        if not bag or not slot then
            PrintNice(L["Usage: /ec scandebug <bag> <slot>"])
            return
        end
        if NS.ShowScanDebugDump then
            NS.ShowScanDebugDump(bag, slot)
        else
            PrintNice("|cffff4444Scan debug helper unavailable.|r")
        end
        return
    end

    if cmd == "captureproc" then
        -- v2.48.1: chance-on-hit proc capture diagnostic. Opens a
        -- copyable window with every bag item's chance-on-hit line,
        -- every spellbook 'engrave this affix' spell tooltip, and the
        -- full _G.ExtractionService.learnedAffixes catalog schema.
        -- Data-gathering for the future runtime translation table that
        -- pairs item-side proc lines with extracted-affix spell names.
        if NS.ShowCaptureProcDump then
            NS.ShowCaptureProcDump()
        else
            PrintNice("|cffff4444Capture-proc helper unavailable.|r")
        end
        return
    elseif cmd == "pairaudit" then
        -- v2.75.0: check every recorded chance-on-hit itemID against the
        -- client's item data. Catches an itemID typo in the hand-entered
        -- pairing tables, which is otherwise invisible - the wrong weapon
        -- just gets released or protected with no error.
        if NS.ShowProcPairAudit then
            NS.ShowProcPairAudit()
        else
            PrintNice("|cffff4444Pair-audit helper unavailable.|r")
        end
        return
    elseif cmd == "paircheck" then
        -- v2.75.0: read candidate weapons' real proc lines straight from
        -- the client, including items the player has never owned, so a
        -- community-sourced pairing can be corroborated without the Anvil
        -- (which needs the physical item). Candidates live in the
        -- diagnostic only; nothing in the sell path reads them.
        if NS.ShowProcPairCheck then
            NS.ShowProcPairCheck()
        else
            PrintNice("|cffff4444Pair cross-check helper unavailable.|r")
        end
        return
    end

    if cmd == "autolearnsim" then
        -- v2.49.1: chance-on-hit proc autolearn simulation harness.
        -- Injects a synthetic entry into EC_recentChanceProcRemovals for
        -- the given itemID, then fires the correlation handler as if
        -- LEARNED_SPELL_IN_TAB had just delivered the given spellID.
        -- Walks the same code path as a production event so we can test
        -- the correlation logic without needing an actual unlearned
        -- weapon proc at the Anvil (most weapon procs already extracted
        -- so real events are hard to trigger).
        local idS, spellS = rest:match("^(%S+)%s+(%S+)")
        local itemID = tonumber(idS)
        local spellID = tonumber(spellS)
        if not itemID or not spellID then
            PrintNice(L["Usage: /ec autolearnsim <itemID> <spellID>"])
            return
        end
        local neverSet = NS.chanceProcNeverExtractable
        if neverSet and neverSet[itemID] then
            PrintNicef(
                L["|cffff4444%s (%d) is in NEVER_EXTRACTABLE; sim refused.|r"],
                neverSet[itemID],
                itemID
            )
            return
        end
        -- Verify the item is in bags so we can read its live proc line.
        local foundBag, foundSlot
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                if GetContainerItemID(bag, slot) == itemID then
                    foundBag, foundSlot = bag, slot
                    break
                end
            end
            if foundBag then
                break
            end
        end
        if not foundBag then
            PrintNicef(
                L["|cffff4444Item %d not in bags; sim needs the item present to read its proc line. Try /ec captureproc first to confirm the proc text.|r"],
                itemID
            )
            return
        end
        local procLine = EC_compCache.chanceProcLine
            and EC_compCache.chanceProcLine(foundBag, foundSlot, itemID)
        if not procLine then
            PrintNicef(
                L["|cffff4444Item %d has no chance-on-hit line detected; sim refused.|r"],
                itemID
            )
            return
        end
        local _, link = GetItemInfo(itemID)
        EC_recentChanceProcRemovals[#EC_recentChanceProcRemovals + 1] = {
            itemID = itemID,
            itemName = link or ("item:" .. itemID),
            procLine = procLine,
            removedAt = GetTime(),
        }
        -- Look up the spell's name from the PE catalog for the toast.
        local catalog = EC_compCache.getExtractionCatalog()
        local rec
        if type(catalog) == "table" then
            for _, r in pairs(catalog) do
                if type(r) == "table" and r.id == spellID then
                    rec = r
                    break
                end
            end
        end
        EC_TryAutolearnFromLearnedSpell(spellID, (rec and rec.name) or nil, "sim")
        PrintNice(L["(sim) autolearn run complete. Check the chat above and /ec autolearnpeek."])
        return
    end

    if cmd == "autolearnpeek" then
        -- v2.49.1: read-only copy-window dump of the autolearn state.
        -- Same style as /ec captureproc, /ec affixdebug dump.
        if NS.ShowAutolearnPeek then
            NS.ShowAutolearnPeek()
        else
            PrintNice(L["|cffff4444Autolearn peek window unavailable.|r"])
        end
        return
    end

    if cmd == "processdebug" then
        -- v2.38.3: one-shot diagnostic for the Process Bags engine.
        -- Opens a copyable window with every gate that decides whether
        -- an item appears in the Disenchant / Mill / Prospect / Lockpick
        -- list (spell-known states, settings, per-slot scan results,
        -- buildProcessSummary entry counts). Players whose herbs / ores
        -- don't show up can paste the output and we can identify which
        -- layer is failing on their setup (private-server spell IDs,
        -- tooltip-marker variance, etc.) before guessing a fix.
        --
        -- Sub-commands:
        --   /ec processdebug         - open the diagnostic window
        --   /ec processdebug clear   - wipe processCache (forces fresh
        --                              tooltip scans on the next bag
        --                              walk; lets us confirm whether a
        --                              "none" entry is genuine or
        --                              cache-poisoned from a /reload
        --                              tooltip race)
        local sub = (rest:match("^(%S+)") or ""):lower()
        if sub == "clear" then
            if EC_compCache and EC_compCache.processCache then
                local n = 0
                for _ in pairs(EC_compCache.processCache) do
                    n = n + 1
                end
                for k in pairs(EC_compCache.processCache) do
                    EC_compCache.processCache[k] = nil
                end
                PrintNicef(L["|cffb6ffb6Process cache cleared|r (%d entry/entries removed). Re-run |cffffff00/ec processdebug|r to scan fresh."], n)
            else
                PrintNice(L["|cffff4444processCache not available.|r"])
            end
            return
        end
        if NS.ShowProcessDebugDump then
            NS.ShowProcessDebugDump()
        else
            PrintNice(L["|cffff4444Process debug dump is unavailable.|r"])
        end
        return
    end

    if cmd == "sellinfo" then
        EnsureDB()
        -- Optional positional args: bag, slot. Defaults to the first
        -- non-empty bag slot when omitted.
        local bagArg, slotArg = rest:match("^%s*(%S+)%s+(%S+)%s*$")
        local bag = tonumber(bagArg)
        local slot = tonumber(slotArg)
        if EC_compCache.printSellabilityTrace then
            EC_compCache.printSellabilityTrace(bag, slot)
        end
        return
    end

    if cmd == "loot" then
        EnsureDB()
        if NS.ToggleLootWindow then
            NS.ToggleLootWindow()
        end
        return
    end

    if cmd == "history" then
        EnsureDB()
        NS.ShowSessionHistory()
        return
    end

    if cmd == "perf" then
        -- v2.37.6: self-diagnostic for "is EC bloated / hot?". Surfaces
        -- the four numbers that actually answer the question: addon
        -- memory footprint, addon CPU cost (when scriptProfile is on),
        -- the per-itemID cache sizes (bounded by unique items seen),
        -- and the user's list sizes. Also flags affixdebug if it's
        -- been left on after a diagnostic session.
        local function countKeys(t)
            if type(t) ~= "table" then
                return 0
            end
            local n = 0
            for _ in pairs(t) do
                n = n + 1
            end
            return n
        end
        if UpdateAddOnMemoryUsage then
            UpdateAddOnMemoryUsage()
        end
        local memKb = GetAddOnMemoryUsage and GetAddOnMemoryUsage("EbonClearance") or 0
        PrintNice(L["|cffffff00=== EbonClearance perf ===|r"])
        PrintNicef(L["Memory: |cffb6ffb6%.1f KB|r"], memKb)
        local profileOn = GetCVarBool and GetCVarBool("scriptProfile")
        if profileOn then
            if UpdateAddOnCPUUsage then
                UpdateAddOnCPUUsage()
            end
            local cpuMs = GetAddOnCPUUsage and GetAddOnCPUUsage("EbonClearance") or 0
            local fps = (GetFramerate and GetFramerate()) or 60
            if fps < 1 then
                fps = 1
            end
            PrintNicef(
                L["CPU: |cffb6ffb6%.1f ms total|r (%.3f ms/frame avg at %.0f FPS)"],
                cpuMs, cpuMs / fps, fps
            )
        else
            PrintNice(
                L["|cff888888CPU profile is off. Enable with /console set scriptProfile 1 then /reload to see CPU numbers here.|r"]
            )
        end
        PrintNicef(
            L["Caches: %d affix / %d hit-proc / %d tome / %d processable / %d bind / %d item-affix"],
            countKeys(EC_compCache.affixDataCache),
            countKeys(EC_compCache.chanceOnHitCache),
            countKeys(EC_compCache.tomeCache),
            countKeys(EC_compCache.processCache),
            countKeys(EC_compCache.bindCache),
            countKeys(EC_compCache.itemAffixLookupCache)
        )
        if DB then
            PrintNicef(
                L["Lists: %d sell / %d keep / %d delete / %d account-sell"],
                countKeys(DB.whitelist),
                countKeys(DB.blacklist),
                countKeys(DB.deleteList),
                (ADB and countKeys(ADB.whitelist)) or 0
            )
        end
        if ADB then
            PrintNicef(
                L["Side meta: %d (affix-gated) / %d (Hit-proc)"],
                countKeys(ADB.affixedListedItems),
                countKeys(ADB.chanceOnHitListedItems)
            )
            if ADB.affixDebugEnabled then
                local rows = (ADB.affixDebug and ADB.affixDebug.rows) or {}
                PrintNicef(
                    L["|cffffb84daffixdebug ON|r - %d rows logged. Turn off with /ec affixdebug off when you're done."],
                    #rows
                )
            end
        end
        return
    end

    if cmd == "spike" then
        -- Session frame-hitch diagnostic: the worst recent frames EC
        -- contributed to and which phase (bag update / vendor / tooltip)
        -- was busiest during each. Complements /ec perf (which reports
        -- steady-state footprint) by answering "what caused that stutter?".
        EnsureDB()
        NS.ShowFrameSpikes()
        return
    end

    if cmd == "bubbles" then
        -- Bubble-mute diagnostic: what the chat filter tracked vs what the
        -- bubble walker read off screen, with match verdicts. For debugging
        -- a Scavenger bubble that escapes the mute (e.g. a new server-side
        -- bot line whose chat text differs from its bubble text).
        EnsureDB()
        if NS.ShowBubbleDiag then
            NS.ShowBubbleDiag()
        end
        return
    end

    if cmd == "affixfallback" then
        -- Affix-source resilience check. Forces EC to ignore Project
        -- Ebonhold's affix data and rebuild its known-affix map from the
        -- spellbook alone, so the fallback path is verifiable in-game.
        -- Session-only; cleared on /reload. See getExtractionCatalog in
        -- EbonClearance_Protection.lua.
        EnsureDB()
        local sub = rest and rest:lower() or ""
        local function countKeys(t)
            local n = 0
            if type(t) == "table" then
                for _ in pairs(t) do
                    n = n + 1
                end
            end
            return n
        end
        if sub == "on" or sub == "off" then
            EC_compCache.simulateExtractionAbsent = (sub == "on")
            if EC_compCache.refreshKnownAffixes then
                EC_compCache.refreshKnownAffixes()
            end
            if sub == "on" then
                PrintNice(
                    L["|cffffb84dAffix fallback simulation ON.|r EbonClearance is now ignoring Project Ebonhold's affix data and using only your spellbook."]
                )
            else
                PrintNice(L["|cffb6ffb6Affix fallback simulation OFF.|r Back to normal (Project Ebonhold data + your spellbook)."])
            end
            PrintNice(
                L["|cff888888Rebuilding your affix map. Re-run /ec affixfallback in a moment to see the counts settle, and check your bag affix highlighting still works.|r"]
            )
            return
        end
        local live = (_G.ExtractionService and type(_G.ExtractionService.learnedAffixes) == "table") and "present"
            or "absent"
        if EC_compCache.simulateExtractionAbsent then
            PrintNice(L["|cffffb84dAffix fallback simulation: ON|r (using your spellbook only)."])
        else
            PrintNice(L["|cffb6ffb6Affix fallback simulation: OFF|r (normal)."])
        end
        PrintNicef(
            L["Known affixes: %d descriptions / %d families. Project Ebonhold affix data: %s."],
            countKeys(EC_compCache.knownAffixDescriptions),
            countKeys(EC_compCache.knownAffixFamilyRanks),
            live
        )
        PrintNice(
            L["|cff888888/ec affixfallback on simulates PE's affix data being gone; off restores it. The counts should stay similar either way - that's your affix protection surviving on the spellbook alone.|r"]
        )
        return
    end

    if cmd == "help" or cmd == "?" then
        -- v2.37.6: slimmed to a 2-line redirect. The Main panel's Slash
        -- Commands section is now the canonical reference (each command
        -- has a click-to-run button), so the chat dump that used to
        -- live here is duplication. Keeps the command so the
        -- conventional /<addon> help expectation still gives a useful
        -- response.
        PrintNice(L["|cffffff00EbonClearance|r: type |cffffff00/ec|r to open settings."])
        PrintNice(
            L["|cffaaaaaaThe Slash Commands section there has every command with click-to-run buttons. The Help panel in Interface Options has the full FAQ.|r"]
        )
        return
    end

    if cmd == "clean" then
        EnsureDB()
        -- v2.12.0: subcommand fork. "/ec clean upgrades [apply]" walks the
        -- DB.blacklistAuto entries with tag "upgrade" and reports / removes
        -- ones that are no longer upgrades vs current gear (cleans up the
        -- spurious entries the v2.11.0 empty-slot bug left on user lists).
        -- Existing "/ec clean [apply]" cross-list conflict resolver is
        -- unchanged.
        if rest == "upgrades" or rest == "upgrades apply" then
            local report = EC_compCache.buildStaleUpgradeReport()
            local nStale = #report.stale
            local nDeferred = #report.deferred
            local nSkipped = #report.skipped
            if nStale == 0 and nDeferred == 0 and nSkipped == 0 then
                PrintNice(L["|cffaaaaaaNo 'Upgrade'-tagged entries on your Keep List.|r"])
                return
            end
            PrintNicef(
                L["|cffffff00%d|r stale 'Upgrade' entr%s found (no longer above your equipped iLvl)."],
                nStale,
                nStale == 1 and "y" or "ies"
            )
            if nStale > 0 then
                local cap = math.min(nStale, 10)
                for i = 1, cap do
                    local s = report.stale[i]
                    PrintNicef(
                        L["  |cffaaaaaa[%d]|r %s |cffaaaaaa(iLvl %d, equipped %d)|r"],
                        s.id,
                        s.name,
                        s.iLvl,
                        s.lowestEquipped
                    )
                end
                if nStale > cap then
                    PrintNicef(L["  |cffaaaaaa... and %d more.|r"], nStale - cap)
                end
            end
            if nDeferred > 0 then
                PrintNicef(
                    L["|cffaaaaaaDeferred %d entr%s (item info not loaded; rerun the command later).|r"],
                    nDeferred,
                    nDeferred == 1 and "y" or "ies"
                )
            end
            if nSkipped > 0 then
                PrintNicef(
                    L["|cffaaaaaaSkipped %d entr%s (no candidate slot populated to compare against).|r"],
                    nSkipped,
                    nSkipped == 1 and "y" or "ies"
                )
            end
            if rest == "upgrades apply" and nStale > 0 then
                local dialog = StaticPopup_Show("EC_CONFIRM_CLEAN_UPGRADES", nStale)
                if dialog then
                    dialog.data = function()
                        local removed = EC_compCache.applyStaleUpgradeCleanup(report)
                        PrintNicef(
                            L["Removed |cffffff00%d|r stale 'Upgrade' entr%s from the Keep List."],
                            removed,
                            removed == 1 and "y" or "ies"
                        )
                        local bp = _G["EbonClearanceOptionsBlacklist"]
                        if bp and bp.listUI then
                            bp.listUI:Refresh()
                        end
                    end
                end
            elseif nStale > 0 then
                PrintNice(L["Run |cffffff00/ec clean upgrades apply|r to remove them."])
            end
            return
        end
        local conflicts = EC_ScanListConflicts()
        EC_PrintConflictReport(conflicts)
        if rest == "apply" and #conflicts > 0 then
            local removed = EC_ApplyCleanResolution(conflicts)
            PrintNicef(
                L["Removed |cffffff00%d|r duplicate entr%s (precedence: blacklist > deleteList > whitelist)."],
                removed,
                removed == 1 and "y" or "ies"
            )
            local wp = _G["EbonClearanceOptionsWhitelist"]
            if wp and wp.listUI then
                wp.listUI:Refresh()
            end
            local bp = _G["EbonClearanceOptionsBlacklist"]
            if bp and bp.listUI then
                bp.listUI:Refresh()
            end
        elseif #conflicts > 0 then
            PrintNice(L["Run |cffffff00/ec clean apply|r to auto-resolve (blacklist > deleteList > whitelist)."])
        end
        return
    end

    -- Unknown subcommand - open options
    NS.OpenOptionsPanel("EbonClearanceOptionsMain")
end

SLASH_ECDEBUG1 = "/ecdebug"
SlashCmdList["ECDEBUG"] = function()
    if not DB then
        PrintNice(L["|cffff4444DB not loaded.|r"])
        return
    end
    PrintNice(L["|cffffff00=== EbonClearance Debug ===|r"])
    for q = 1, 4 do
        local r = DB.qualityRules and DB.qualityRules[q] or {}
        local rarityName = (q == 1) and "White" or (q == 2) and "Green" or (q == 3) and "Blue" or "Epic"
        local capStr = (r.maxILvl and r.maxILvl > 0) and tostring(r.maxILvl) or "no cap"
        PrintNicef("Quality[%s]: enabled=%s, max iLvl=%s", rarityName, tostring(r.enabled), capStr)
    end

    -- Print whitelist contents
    local wlCount = 0
    for k, v in pairs(DB.whitelist or {}) do
        local n = GetItemInfo(k) or ("ItemID:" .. tostring(k))
        PrintNicef("  Sell List[%s] = %s  (%s)", tostring(k), tostring(v), n)
        wlCount = wlCount + 1
    end
    if wlCount == 0 then
        PrintNice(L["  (whitelist is empty)"])
    end

    -- Scan bags and check which items would be sold. v2.13.4: routes
    -- through EC_IsSellable so the debug output reflects every check
    -- the live merchant cycle applies. The previous inline predicate
    -- was missing v2.10.0+ rules (bind filter, Use equipped iLvl,
    -- quest-item safety net, blacklist veto, IsEquippedItem veto)
    -- and silently produced wrong "would sell" answers for items
    -- those checks cover. The breakdown columns (junk/wp/qp) are now
    -- inferred from EC_IsSellable's authoritative outcome plus the
    -- two cheap stable predicates (isJunk and whitelistPass) computed
    -- locally.
    PrintNice(L["|cffffff00--- Bag scan ---|r"])
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local sellable, _, _, _, _ = EC_IsSellable(bag, slot, false)
                if sellable then
                    local name, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
                    local junk = (quality ~= nil) and (quality == 0) and sellPrice and sellPrice > 0
                    local wp = IsInSet(DB.whitelist, itemID) or (ADB and IsInSet(ADB.whitelist, itemID))
                    -- Quality-rule path is whatever's left when the
                    -- authoritative EC_IsSellable says yes but neither
                    -- of the explicit list/junk paths matched.
                    local qp = sellable and not junk and not wp
                    PrintNicef(
                        "|cff00ff00SELL|r bag=%d slot=%d id=%d q=%s junk=%s wp=%s qp=%s sp=%s name=%s",
                        bag,
                        slot,
                        itemID,
                        tostring(quality),
                        tostring(junk),
                        tostring(wp),
                        tostring(qp),
                        tostring(sellPrice),
                        tostring(name)
                    )
                end
            end
        end
    end
    PrintNice(L["|cffffff00=== End Debug ===|r"])
end

-- v2.49.2: detects a third-party auto-delete addon running alongside
-- EC. Called at PLAYER_LOGIN (chat warning) and by /ec bugreport
-- (Environment Capabilities line). Only the IsAddOnLoaded string is
-- specific; comments + variable names stay neutral per CLAUDE.md's
-- "No third-party addon references in new EC artefacts" rule.
local function EC_HasConflictingDeleteAddon()
    return (IsAddOnLoaded and IsAddOnLoaded("AutoDelete")) and true or false
end
NS.HasConflictingDeleteAddon = EC_HasConflictingDeleteAddon

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")
-- BAG_UPDATE drives auto-loot-cycle bag-full detection. Cheap handler;
-- early-returns unless STATE.LOOTING + cycle enabled. See EC_HandleBagFullForCycle.
f:RegisterEvent("BAG_UPDATE")
-- v2.25.0: ITEM_LOCK_CHANGED fires when a bag slot's `locked` flag
-- transitions - either a transient mid-pickup lock or a Pick Lock /
-- key-use unlock. BAG_UPDATE does NOT fire for lock-state changes
-- because the slot's contents haven't changed, so Pick Lock leaves
-- the Process Bags panel showing a stale row + the auto-open driver
-- unaware that the box is now openable. Routing this event through
-- the same debounce frame as BAG_UPDATE refreshes the panel, fires
-- the auto-open driver, and re-arms the cast button.
f:RegisterEvent("ITEM_LOCK_CHANGED")
-- LOOT_CLOSED feeds the loot-silence stuck signal in EC_IsLootSilenceStuck.
-- Pushes one timestamp per corpse looted; pruned lazily on the 5 s pet tick.
-- Only accumulates while DB.autoLootCycle is on, so cycle-off users pay nothing.
f:RegisterEvent("LOOT_CLOSED")
-- UNIT_AURA fires per-unit. The player-only form is much cheaper in raids
-- than an unfiltered registration; fall back on clients that lack it.
if f.RegisterUnitEvent then
    f:RegisterUnitEvent("UNIT_AURA", "player")
else
    f:RegisterEvent("UNIT_AURA")
end
-- v2.9.2: track player-only profession-cast successes so the LOOT_CLOSED
-- handler can suppress the loot-silence ring push when the loot was
-- triggered by a craft / disenchant / mill / prospect / lockpick rather
-- than a corpse loot. RegisterUnitEvent("player") avoids firing for
-- party/raid casts (irrelevant traffic), with the unfiltered fallback
-- for clients that lack it.
if f.RegisterUnitEvent then
    f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
else
    f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end
-- v2.10.0: drives the auto-protect-equipped reactive path. Fires every time
-- the player swaps a gear slot; the handler routes through
-- EC_AutoProtectEquippedSlot which short-circuits when the toggle is off,
-- so users not opted in pay one early-return per swap.
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
-- v2.13.0: drives the Equipment Manager protection re-sync when the user
-- adds, modifies, or deletes a saved equipment set via the Blizzard
-- Equipment Manager. Handler is gated on DB.autoProtectEquipmentSets so
-- users without the toggle on pay one early-return per set save.
f:RegisterEvent("EQUIPMENT_SETS_CHANGED")
-- v2.23.0: drives the known-affix refresh for the exact-dupe gate.
-- LEARNED_SPELL_IN_TAB fires when a new spell is added to the
-- spellbook (covers PE affix extraction). SPELLS_CHANGED fires after
-- the spellbook is fully populated post-login and on bulk updates.
-- Both handlers re-scan and rebuild the description map.
f:RegisterEvent("LEARNED_SPELL_IN_TAB")
f:RegisterEvent("SPELLS_CHANGED")
-- Wakes the auto-open-containers driver when combat ends. Without this the
-- combat-deferred queue could sit indefinitely if no further BAG_UPDATE
-- arrives. Handler self-gates on DB.autoOpenContainers, so users with the
-- toggle off pay one early-return per combat exit.
f:RegisterEvent("PLAYER_REGEN_ENABLED")
-- v2.16.0: drives the Fast Loot driver. Handler self-gates on
-- DB.fastLoot and on Blizzard's autoLootDefault CVar, so users without
-- the toggle on pay one early-return per loot interaction.
f:RegisterEvent("LOOT_READY")
-- Group-roster events for version-gossip probes. WoW 3.3.5a equivalents;
-- GROUP_ROSTER_UPDATE is 4.0+ and must not be used here.
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            EnsureDB()
            -- Scrub orphans from the v2.2.0 scoping bug where these names
            -- briefly leaked into _G. Harmless if absent. See v2.2.1 fix.
            _G.EC_summonGoblinPending = nil
            _G.EC_summonGoblinTimer = nil
            -- Defensive nil-guards around the NS bootstrap chain. A
            -- missing or partial-sync split file is the most common
            -- failure mode during development (one .lua not yet
            -- copied to the live addon folder); without these guards
            -- a single missing file kills the whole init chain at the
            -- nil call site, hiding which subsystem actually failed
            -- to load.
            if NS.HookDeletePopupOnce then NS.HookDeletePopupOnce() end
            EC_InstallFastLootHookOnce()
            if NS.ApplyGreedyChatFilter then NS.ApplyGreedyChatFilter() end
            if NS.CreateMinimapButton then NS.CreateMinimapButton() end
            if NS.InstallTooltipHookOnce then NS.InstallTooltipHookOnce() end
            if NS.CreateLDBLauncher then NS.CreateLDBLauncher() end
            if NS.CreateTargetMerchantButton then NS.CreateTargetMerchantButton() end
            if NS.InstallBagContextHookOnce then NS.InstallBagContextHookOnce() end
            if EC_manualSell and EC_manualSell.installHookOnce then
                EC_manualSell.installHookOnce()
        EC_compCache.installExternalActionHooksOnce()
            end
            -- v2.49.1: prime the extraction catalog snapshot so the first
            -- LEARNED_SPELL_IN_TAB event correctly diffs against login
            -- state (learned=true records already in the catalog don't
            -- fire spurious autolearns).
            EC_RefreshExtractionCatalogSnapshot()
        elseif addonName == "Bagnon" then
            -- The host bag UI's slot class was registered during its load
            -- pass; install the sell-border hook now so the first paint
            -- after bags open already runs through our refresh path. The
            -- PLAYER_LOGIN-deferred fallback further down is idempotent so
            -- double-firing is harmless.
            if EC_compCache.installHostBagBorderHook then
                EC_compCache.installHostBagBorderHook()
            end
            if EC_compCache.installHostBagItemLevelHook then
                EC_compCache.installHostBagItemLevelHook()
            end
        end
    elseif event == "PLAYER_LOGOUT" then -- luacheck: ignore 542
        -- No-op. The previous body (`EbonClearanceDB = DB`) was a defensive
        -- mirror back to the saved-variable when DB == EbonClearanceDB.
        -- After the v2.34.x per-character partition, DB is a metatable
        -- proxy, NOT the saved table itself; reassigning EbonClearanceDB
        -- to the proxy would replace the SV with an empty table and
        -- wipe the user's data on next logout. WoW serialises whatever
        -- EbonClearanceDB points to natively; we don't need to nudge it.
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- EnsureDB is load-bearing at PLAYER_LOGIN (the real character key is
        -- available there; ADDON_LOADED already ran it once for early reads).
        -- PLAYER_ENTERING_WORLD re-fires on every loading screen (zone change,
        -- instance, taxi) and nothing in the DB shape can change between
        -- those, so skip the full migration sweep + proxy rebuild there.
        if event == "PLAYER_LOGIN" then
            EnsureDB()
        end
        if NS.InstallGreedyMuteOnce then
            NS.InstallGreedyMuteOnce()
        end
        -- v2.65.0 (Alckor request): capture "was bootstrap already done"
        -- BEFORE the bootstrap block runs, so the re-summon block below
        -- can distinguish first PLAYER_ENTERING_WORLD (login / /reload -
        -- skip re-summon; the bootstrap seeds lastScavengerOut but that
        -- reflects the login-time state, not a pre-load-screen state)
        -- from subsequent PLAYER_ENTERING_WORLDs (zone change - re-
        -- summon is valid because lastScavengerOut IS the pre-load state).
        local wasBootstrapped = EC_scavStateBootstrapped
        -- One-time companion-state bootstrap so the OnUpdate movement
        -- accumulator can start counting immediately if the Scavenger was
        -- already out at /reload (otherwise we wait for the first 5 s tick
        -- to observe the state and lose that much accumulation).
        if not EC_scavStateBootstrapped then
            local _, scavOut = EC_FindGreedyScavenger()
            if scavOut then
                EC_compCache.lastScavengerOut = true
            end
            EC_scavStateBootstrapped = true
        end
        -- v2.65.0 (Alckor request): re-summon the Scavenger after ANY
        -- loading screen if the pet was out immediately before it.
        -- PLAYER_ENTERING_WORLD fires on every loading-screen finish; the
        -- "was pet out beforehand" signal is EC_compCache.lastScavengerOut,
        -- which the OnUpdate movement accumulator has been tracking
        -- continuously up to the load-screen pause. Gated on:
        --   (a) wasBootstrapped - skip first PLAYER_ENTERING_WORLD after
        --       login/reload; that's not a zone-change signal
        --   (b) DB.summonGreedy (master Scavenger toggle) - respect
        --       "user has the pet disabled entirely"
        --   (c) DB.restoreScavengerAfterLoad opt-in toggle - off by
        --       default so no pet-visibility surprise on first upgrade
        --   (d) EC_compCache.lastScavengerOut - only re-summon if the
        --       pet WAS out before the load screen (respects the user's
        --       explicit dismissal decision)
        --   (e) scavenger not currently out - CallCompanion is a no-op
        --       if the pet is somehow already present, but skipping the
        --       delayed call keeps the initiate-summon state machine tidy
        -- Routes through EC_SummonGreedyWithDelay so the summonDelay
        -- setting applies uniformly (default 1.6 s covers the window
        -- between load-screen-finished and Blizzard accepting the call).
        if wasBootstrapped
            and DB
            and DB.summonGreedy
            and DB.restoreScavengerAfterLoad
            and EC_compCache.lastScavengerOut
        then
            local _, scavOut = EC_FindGreedyScavenger()
            if not scavOut then
                EC_SummonGreedyWithDelay()
            end
        end
        -- v2.49.2: conflict warning. Fires only when EC's delete path
        -- is active AND the player hasn't opted out AND a third-party
        -- auto-delete addon is loaded. Modal popup (not a chat line -
        -- a one-time chat message was easy to miss). Neutral framing per
        -- project rule; player identifies the other addon via their own
        -- list. Inside the PLAYER_LOGIN-only branch so it's one-shot per
        -- session (PLAYER_ENTERING_WORLD zone changes don't re-fire it).
        if event == "PLAYER_LOGIN" then
            if DB.enableDeletion and DB.warnConflictingAddons and EC_HasConflictingDeleteAddon() then
                StaticPopup_Show("EC_CONFLICT_WARNING")
            end
        end
        -- v2.51.0: watch-list toggle snapshot at PLAYER_LOGIN, after
        -- EnsureDB has seeded defaults. /ec bugreport diffs against
        -- this to show which toggles the user flipped this session.
        -- No mutation hooks needed; the diff at report time gives us
        -- the "since login" audit trail. Watch list is a curated set of
        -- high-diagnostic-value toggles (destructive / protection /
        -- feature-gating) - not every checkbox in the addon.
        if event == "PLAYER_LOGIN" and NS.CaptureToggleLoginSnapshot then
            NS.CaptureToggleLoginSnapshot()
        end
        -- v2.51.0: warm the client's item cache for Delete List entries
        -- after a short settle so /ec bugreport (later in the session)
        -- can resolve names. Delayed by 5s to let the login-storm
        -- (PLAYER_LOGIN + inventory scans + Blizzard's own cache prime)
        -- settle first. Best-effort - if the delay helper isn't loaded
        -- (Core race) we just skip; user's next bugreport will still
        -- get whatever the client has cached by then.
        if event == "PLAYER_LOGIN" and NS.PrimeDeleteListItemCache then
            if NS.Delay then
                NS.Delay(5, NS.PrimeDeleteListItemCache)
            else
                NS.PrimeDeleteListItemCache()
            end
        end
        -- Version gossip: once per session (login / reload, not zone changes),
        -- after a short settle, ask the guild for versions.
        if event == "PLAYER_LOGIN" then
            NS.Delay(5, function()
                if NS.Comms and GetGuildInfo("player") then
                    NS.Comms.FireVersionProbe("GUILD")
                end
            end)
            -- v2.53.0: initial proc-pairing pull request 6s after login,
            -- one second AFTER the version probe so the two don't overlap.
            -- Opt-in gated at RequestNow (own throttle + toggle check).
            NS.Delay(6, function()
                if EbonClearanceDB and EbonClearanceDB.shareChanceProcs
                    and NS.ProcShare and NS.ProcShare.RequestNow
                then
                    NS.ProcShare.RequestNow()
                end
            end)
            -- v2.58.0: realm-wide bus join 7s after login (one second after
            -- the proc pull so the three settle staggered). Only joins when the
            -- player shares server stats, so a channel slot is never consumed
            -- otherwise. The join also fires one self-suppressing request so the
            -- odometer has data when the panel is first opened - and the version
            -- it carries lets the existing versionAlerts nudge hear the realm.
            NS.Delay(7, function()
                if EbonClearanceDB and EbonClearanceDB.shareServerData
                    and NS.RealmComms and NS.ServerShare and NS.ServerShare.RequestNow
                then
                    NS.RealmComms.Join()
                    NS.ServerShare.RequestNow()
                end
            end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended: re-fire the open driver. If the toggle is off or
        -- the queue is empty the driver early-returns; cost on combat
        -- exit for opted-out users is one branch.
        --
        -- The combatDeferredAnnounced flag is intentionally NOT cleared
        -- here. It used to be (per-combat re-announce), but a tester
        -- rogue-leveling with lockboxes in bag reported the deferral line
        -- firing repeatedly across short mob fights. The announce is now
        -- session-scoped (one per /reload) since its purpose is one-time
        -- discoverability, not a per-combat status reminder.
        EC_HandleAutoOpenContainers()
        -- Drain any settings-panel open that was queued while combat was
        -- active. Same double-call workaround as the original click paths.
        local pendingOpen = EC_compCache.pendingOpenAfterCombat
        if pendingOpen then
            EC_compCache.pendingOpenAfterCombat = nil
            if pendingOpen == "main" then
                NS.OpenOptionsPanel("EbonClearanceOptionsMain")
            elseif pendingOpen == "process" then
                NS.OpenOptionsPanel("EbonClearanceOptionsProcessBags")
            end
        end
        -- v2.22.0: Process Bags cast-button re-arm. SetAttribute is blocked
        -- during combat, so any re-arm attempts from BAG_UPDATE bail and
        -- this combat-exit catch-up restores a current macrotext.
        EC_compCache.rearmProcessButton()
        -- v2.26.0: cheap dirty-check refresh of the known-extraction
        -- description map. PE's ExtractionService updates in-place
        -- after the player extracts at the Anvil; this catches the
        -- state at combat exit without needing a /reload.
        if EC_compCache.refreshExtractionIfDirty then
            EC_compCache.refreshExtractionIfDirty()
        end
        -- v2.25.0: optional one-line nudge when combat ends with
        -- lockable containers in bags. Off by default (one extra line
        -- per combat exit is noisy for rogues farming heavy zones).
        -- Only counts containers, not casts available; the user picks
        -- which one to open via the panel / hold-key-to-drain.
        if
            DB.lockpickEnabled
            and DB.lockpickNotifyOnCombatExit
            and IsSpellKnown
            and IsSpellKnown(EC_compCache.SPELL_PICK_LOCK)
        then
            local n = 0
            for bag = 0, 4 do
                local slots = GetContainerNumSlots(bag) or 0
                for slot = 1, slots do
                    if EC_compCache.canPickLock(bag, slot) then
                        n = n + 1
                    end
                end
            end
            if n > 0 then
                PrintNicef(
                    L["|cffaaaaaa%d lockbox(es) available.|r Click |cffffb84dProcess Next|r in Process Bags to open."],
                    n
                )
            end
        end
    elseif event == "EQUIPMENT_SETS_CHANGED" then
        EC_StampEvent("equipmentSetsChanged")
        -- v2.13.0: live re-sync of Blizzard equipment-manager sets onto
        -- the Keep list. Silent variant suppresses the chat summary so
        -- save-edit-save cycles in the Equipment Manager UI don't spam.
        -- v2.50.2: run the sync UNCONDITIONALLY so EC_compCache.equipmentSetIDs
        -- is rebuilt whether or not autoProtectEquipmentSets is on. The scan-
        -- side rescue (runAutoMarkAffixDupes) consults the cache to veto
        -- auto-marking items in a saved set - that veto MUST hold even when
        -- the automatic Keep-List stamping is opt-out. syncEquipmentSets
        -- itself now gates the Keep-List stamp on the toggle internally.
        if DB then
            EC_compCache.syncEquipmentSets(true)
            if DB.autoProtectEquipmentSets then
                local bp = _G["EbonClearanceOptionsBlacklist"]
                if bp and bp.listUI then
                    bp.listUI:Refresh()
                end
            end
        end
    elseif event == "LEARNED_SPELL_IN_TAB" or event == "SPELLS_CHANGED" then
        -- v2.49.1: chance-on-hit proc autolearn. Run the catalog diff
        -- SYNCHRONOUSLY per event so a single anvil extraction with its
        -- correlated bag-removal (5-second window) is captured in the
        -- same tick. The v2.30.0 debounced known-affix rescan below is
        -- independent and stays debounced. LEARNED_SPELL_IN_TAB is the
        -- richer signal (per-spell fires); SPELLS_CHANGED is the bulk
        -- signal (login / respec), so only the former triggers autolearn.
        if event == "LEARNED_SPELL_IN_TAB" then
            local newSpellID, newRec = EC_FindNewlyLearnedSpell()
            if newSpellID and newRec then
                EC_TryAutolearnFromLearnedSpell(newSpellID, newRec.name, "event")
            end
        end
        -- v2.30.0 perf: debounced. Soul ash tree and login can fire
        -- dozens of spell events in rapid succession; a synchronous
        -- spellbook scan on each one caused 30+ second freezes. Reset
        -- the accumulator on every event so we wait for 0.5 s of quiet
        -- before doing a single rebuild. The actual rebuild is driven
        -- by EC_compCache.spellUpdateFrame's OnUpdate in
        -- EbonClearance_Protection.lua; calling refreshKnownAffixes
        -- directly here would defeat the debounce.
        EC_compCache.spellUpdatePending = true
        EC_compCache.spellUpdateAccum = 0
        EC_compCache.spellUpdateFrame:Show()
        -- Tome "Already known" lookups read the LIVE tooltip via
        -- SetBagItem, so flipping false -> true on a tome the player
        -- just learned needs the cache cleared immediately. The wipe
        -- is cheap (one table reset); doing it synchronously avoids
        -- the 0.5 s debounce window where the next auto-rule sweep
        -- could still treat a just-learned recipe as unlearned and
        -- protect it from vendoring. tomeCache itself isn't wiped
        -- because is-a-tome is stable per itemID.
        if EC_compCache.tomeIsKnownCache then
            wipe(EC_compCache.tomeIsKnownCache)
        end
    elseif event == "BAG_UPDATE" or event == "ITEM_LOCK_CHANGED" then
        -- (The "bagUpdate" bugreport stamp lives in the settled flush, not
        -- here: this raw branch fires once per slot filled during AOE loot
        -- and should stay free of any per-event work beyond the debounce
        -- arm + the synchronous bag-full check.)
        -- v2.24.0 perf: bag-full handler stays synchronous so the
        -- cycle's responsiveness across the free-slot threshold is
        -- unchanged (its internal 1.5 s hysteresis already debounces
        -- transient bag fluctuations). Everything else goes through
        -- EC_compCache.bagUpdateFrame's 120 ms debounce - pet AOE
        -- looting fires one BAG_UPDATE per slot filled, and doing the
        -- full deferred-work chain per-event caused 1.5 s freezes.
        -- v2.25.0: ITEM_LOCK_CHANGED routes through the same debounce
        -- so a Pick Lock completion refreshes the panel + fires the
        -- auto-open driver (which picks up the now-`Right Click to
        -- Open` box). The bag-full handler skips for lock-state
        -- changes (no slot count change so it'd be a no-op anyway).
        if event == "BAG_UPDATE" then
            EC_HandleBagFullForCycle()
        end
        EC_compCache.bagUpdatePending = true
        EC_compCache.bagUpdateAccum = 0
        EC_compCache.bagUpdateFrame:Show()
    elseif event == "LOOT_READY" then
        -- v2.16.0: Fast Loot driver. Self-gates on DB.fastLoot and on
        -- Blizzard's autoLootDefault CVar so non-Fast-Loot users pay
        -- one early-return per loot interaction.
        EC_HandleLootReady()
    elseif event == "LOOT_CLOSED" then
        -- One push per corpse looted. EC_IsLootSilenceStuck prunes the ring
        -- inside its body (called from the 5 s pet tick), so growth is bounded.
        --
        -- v2.9.2 false-positive guards: LOOT_CLOSED also fires for fishing,
        -- disenchanting, milling, prospecting, lockpicking, and opening
        -- engineered containers. The Scavenger doesn't react to any of those,
        -- so counting them as "loot the pet should have answered" produced
        -- false-positive stuck-and-resummon loops for players crafting in
        -- town. Fishing is excluded via IsFishingLoot(); the profession
        -- spells are excluded by the timestamp window populated from
        -- UNIT_SPELLCAST_SUCCEEDED below.
        if DB and DB.autoLootCycle then
            local skip = false
            if IsFishingLoot and IsFishingLoot() then
                skip = true
            elseif (GetTime() - EC_compCache.lastProfLootCastAt) < EC_compCache.PROF_LOOT_WINDOW_S then
                skip = true
            end
            if not skip then
                EC_recentLootTimes[#EC_recentLootTimes + 1] = GetTime()
            end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg1 is the unit (always "player" thanks to RegisterUnitEvent),
        -- arg2 is the spell name. Two timestamps get updated here:
        --
        --   * lastProfLootCastAt - only on loot-generating profession
        --     spells. Drives the loot-silence false-positive guard so
        --     the Scavenger isn't accused of going quiet because the
        --     player was disenchanting / milling / prospecting.
        --
        --   * lastPlayerCastAt - on EVERY successful player cast.
        --     Drives the v2.11.0 GCD-aware busy gate so the goblin
        --     summon retry budget isn't burned on CallCompanion calls
        --     the server silently drops during instant-cast rotations.
        local _, spellName = ...
        if spellName and EC_compCache.PROF_LOOT_SPELLS[spellName] then
            EC_compCache.lastProfLootCastAt = GetTime()
        end
        EC_compCache.lastPlayerCastAt = GetTime()
        -- v2.37.0: Process Bags lifetime cast counters. Counts every
        -- successful Disenchant / Milling / Prospecting / Pick Lock,
        -- whether the cast came from the Process Bags secure button
        -- or a manual cast bar. "Opening" is excluded - it fires on
        -- every container right-click and would over-attribute.
        if DB and spellName and EC_compCache.PROF_LOOT_SPELLS[spellName] and spellName ~= "Opening" then
            -- v2.38.1: helper writes to DB + ADB.accountStats.
            EC_BumpStatBucket("processCastCounts", spellName, 1)
        end
        -- v2.59.4: consume pendingProcessCast if the successful spell
        -- matches what the Process Bags panel captured just before the
        -- macrotext ran. Log to NS.recentProcessedLog and clear the
        -- pending struct. If the spell doesn't match, leave pending
        -- alone (a bumped Auto Attack, self-heal, etc. shouldn't
        -- consume the DE/Mill/Prospect/Pick Lock capture).
        do
            local pending = EC_compCache.pendingProcessCast
            if pending and spellName and pending.spellName == spellName then
                if NS.LogRecentProcessed then
                    NS.LogRecentProcessed(pending)
                end
                EC_compCache.pendingProcessCast = nil
            end
        end
        -- v2.25.0: Pick Lock completion - BAG_UPDATE doesn't fire for a
        -- lockbox's lock-state change (slot contents unchanged), and
        -- ITEM_LOCK_CHANGED doesn't reliably fire either. UNIT_SPELLCAST_SUCCEEDED
        -- with the Pick Lock spell name is the most reliable trigger.
        -- Route through the same debounce frame as BAG_UPDATE so the
        -- panel refreshes (drops the now-unlocked row) and the auto-
        -- open driver fires (opens the now-`Right Click to Open` box).
        if spellName and EC_compCache.PICK_LOCK_NAME and spellName == EC_compCache.PICK_LOCK_NAME then
            EC_compCache.bagUpdatePending = true
            EC_compCache.bagUpdateAccum = 0
            EC_compCache.bagUpdateFrame:Show()
        end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- v2.10.0: auto-protect equipped gear. arg1 is the slot id (1-19);
        -- empty slots fire too (the player just un-equipped). The helper
        -- gates on DB.autoAddEquipped, skips shirt/tabard, and bails when
        -- the slot is empty. On a successful add it prints one targeted
        -- chat line and stamps DB.blacklistAuto so the tooltip annotation
        -- can label the entry as "(auto-protected: equipped)".
        if not (DB and DB.autoAddEquipped) then
            return
        end
        local slot = ...
        if EC_compCache.protectEquipSlot(slot) then
            local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
            local id = link and tonumber(link:match("item:(%d+)"))
            local itemName = (id and GetItemInfo(id)) or "item"
            PrintNicef(L["Auto-protected |cffb6ffb6%s|r (added to Keep list)."], itemName)
            local bp = _G["EbonClearanceOptionsBlacklist"]
            if bp and bp.listUI then
                bp.listUI:Refresh()
            end
        end
    elseif event == "MERCHANT_SHOW" then
        EC_StampEvent("merchantShow")
        EnsureDB()
        EC_merchantReminderPending = false
        EC_batchTotalSold = 0
        EC_batchTotalGold = 0
        EC_compCache.batchTotalDeleted = 0
        EC_keepBagsFlag = true
        -- v2.9.0: snapshot bag contents BEFORE StartRun fires its first sell.
        -- The hooksecurefunc on UseContainerItem reads this map to attribute
        -- right-click sells (which empty the slot before the hook callback
        -- runs); the worker path is excluded by EC_manualSell.inSelfSell. Captured even
        -- when the addon is disabled for this character so manual sells at a
        -- merchant the user opened by hand are still tracked.
        EC_manualSell.snapshotBags()
        if DB and DB.autoLootCycle then
            EC_compCache.lootCycleState = STATE.SELLING
        end
        if not EC_IsAddonEnabledForChar() then
            return
        end
        NS.InstallGreedyMuteOnce()
        StartRun()
    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" and DB and DB.summonGreedy and EC_IsAddonEnabledForChar() then
            local mounted = IsMounted()
            if mounted and not EC_wasMounted then
                -- Only dismiss if the Scavenger is actually out. A bare
                -- DismissGreedyScavenger() on a non-event would set
                -- EC_addonDismissed=true and trick the unmount branch into
                -- "restoring" something the user actively dismissed.
                local _, scavOut = EC_FindGreedyScavenger()
                if scavOut then
                    DismissGreedyScavenger()
                    EC_mountDismissTime = GetTime()
                end
            elseif not mounted and EC_wasMounted then
                -- Restore only if the addon dismissed for the mount. A
                -- manual portrait dismiss before mount-up never set
                -- EC_addonDismissed=true (the mount-up branch above gates
                -- on `if scavOut` first), so this naturally honours it.
                if EC_compCache.addonDismissed then
                    EC_SummonGreedyWithDelay()
                end
            end
            EC_wasMounted = mounted
        end
    elseif event == "MERCHANT_CLOSED" then
        EC_StampEvent("merchantClosed")
        EC_compCache.vendorRunning = false
        worker:Hide()
        -- v2.46.4: merchant gone, drop any refusal marks so the next
        -- visit retries afresh. Cheap insurance alongside the
        -- StartRun wipe (covers player-closes-merchant-mid-loop).
        wipe(EC_vendorRefusedThisRun)
        EC_compCache.pendingDelete = nil
        -- Reset cycle state so the stuck detection can re-summon the Scavenger
        if EC_compCache.lootCycleState == STATE.SELLING then
            EC_compCache.lootCycleState = STATE.IDLE
        end
        -- Reopen bags after merchant closes
        if DB and DB.keepBagsOpen and EC_keepBagsFlag then
            EC_Delay(0.8, EC_OpenAllBags)
        end
        EC_keepBagsFlag = false
    elseif event == "PARTY_MEMBERS_CHANGED" then
        -- Probe the party only when not in a raid (raid uses its own event).
        if NS.Comms and GetNumRaidMembers() == 0 and GetNumPartyMembers() > 0 then
            NS.Comms.FireVersionProbe("PARTY")
        end
    elseif event == "RAID_ROSTER_UPDATE" then
        if NS.Comms and GetNumRaidMembers() > 0 then
            NS.Comms.FireVersionProbe("RAID")
        end
    end

    if event == "PLAYER_LOGIN" then
        EC_Delay(1, function()
            -- v2.38.0: fresh installs auto-open the Quickstart panel
            -- directly (no welcome popup). Existing characters keep the
            -- unchanged single-line welcome.
            if DB and DB._needsQuickstartOpen then
                DB._needsQuickstartOpen = nil
                PrintNice(
                    L["|cffffff00Welcome to EbonClearance!|r Opening Quickstart - pick a preset or answer a few questions to set up."]
                )
                -- Extra 0.3s defer so the UI has finished settling
                -- before the standalone Quickstart frame floats up.
                EC_Delay(0.3, function()
                    local qf = _G["EbonClearanceOptionsQuickstart"]
                    if qf and qf.Show then
                        qf:Show()
                    end
                end)
            else
                PrintNice(L["Enabled. Use |cff00ff00/ec|r to configure."])
            end
            -- Fresh-install one-shot equipped sync. Set in EnsureDB only
            -- when the SavedVariable was nil at first ADDON_LOADED, so
            -- existing characters never trigger this. The 2 s extra
            -- defer (on top of the 1 s welcome delay) gives inventory
            -- APIs time to settle before walking the slots.
            if EC_compCache.pendingFreshInstallSync then
                EC_compCache.pendingFreshInstallSync = nil
                EC_Delay(2, function()
                    if EC_compCache.syncEquipped then
                        EC_compCache.syncEquipped()
                    end
                end)
            end
            -- v2.13.0 ElvUI bag buttons. ElvUI's container frame is
            -- constructed lazily during its own load sequence; the 2 s
            -- defer (on top of the 1 s PLAYER_LOGIN delay) is borrowed
            -- from AutoDelete's matching feature and is enough on every
            -- realm we've seen. Self-gates on _G.ElvUI_ContainerFrame at
            -- call time, so non-ElvUI users pay one nil-check per login.
            EC_Delay(2, function()
                if EC_compCache.buildElvUIBagButtons then
                    EC_compCache.buildElvUIBagButtons()
                end
            end)
            -- Sell-border tint: try installing the host bag-UI adapter
            -- IMMEDIATELY (the common case: host already loaded by
            -- PLAYER_LOGIN). If the host's slot class isn't ready yet, the
            -- call self-gates on LibStub + AceAddon presence and no-ops;
            -- the 2 s fallback below catches the late-load case. Both
            -- calls are idempotent via _hostBagBorderHookInstalled. Without
            -- the immediate attempt, bags opened during the 2 s window
            -- paint without our hook attached and the first border only
            -- appears after the next host-driven slot refresh.
            if EC_compCache.installHostBagBorderHook then
                EC_compCache.installHostBagBorderHook()
            end
            if EC_compCache.installHostBagItemLevelHook then
                EC_compCache.installHostBagItemLevelHook()
            end
            EC_Delay(2, function()
                if EC_compCache.installHostBagBorderHook then
                    EC_compCache.installHostBagBorderHook()
                end
                if EC_compCache.installHostBagItemLevelHook then
                    EC_compCache.installHostBagItemLevelHook()
                end
            end)
            -- v2.23.0: initial spellbook scan for known affixes. The
            -- 2 s defer (same logic as the ElvUI bind above) gives the
            -- spellbook time to fully populate after login. Subsequent
            -- updates are driven by the LEARNED_SPELL_IN_TAB and
            -- SPELLS_CHANGED events registered below.
            EC_Delay(2, function()
                if EC_compCache.refreshKnownAffixes then
                    EC_compCache.refreshKnownAffixes()
                end
            end)
        end)
    end
end)
