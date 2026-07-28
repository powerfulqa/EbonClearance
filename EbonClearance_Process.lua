-- EbonClearance_Process - Process Bags engine (Disenchant / Mill / Prospect / Lockpick).
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 7 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. This file owns the Process Bags ENGINE (the eligibility
-- predicates and the bag-walk summary). The Process Bags PANEL (UI
-- side, including rearmProcessButton / refreshProcessPanel /
-- updateProcessSelection / skipProcessTarget) lives in
-- EbonClearance_ProcessBagsPanel.lua, which composes the UI-building
-- helpers (MakeHeader, AddCheckbox, CreateListUI, FitScrollContent, etc.).
--
-- Moved into this file:
--   * Spell ID constants: SPELL_DISENCHANT, SPELL_MILLING, SPELL_PROSPECTING,
--     SPELL_PICK_LOCK, PICK_LOCK_NAME
--   * Eligibility predicates: canDisenchant, canMill, canProspect, canPickLock
--   * processTooltipHasLine (tooltip-scan helper used by canMill / canProspect)
--   * processIsSoulbound (BoP check used by buildProcessSummary)
--   * buildProcessSummary (the bag walk + categorisation driver)
--
-- Every helper is attached to EC_compCache (= NS.compCache, declared
-- in Core), so call sites elsewhere in the addon already resolve via
-- the shared cache. No call-site changes needed for the cache helpers.
--
-- Cross-file dependencies read inline at call time:
--   * NS.compCache              (Core) - eligibility caches
--                                 (processCache, chanceOnHitCache,
--                                 affixDataCache, etc.)
--   * NS.scanTooltip            (EbonClearance_Events.lua) - the private named
--                                 GameTooltip used for SetBagItem scans
--   * NS.DB / NS.ADB            (EbonClearance_Events.lua via EnsureDB /
--                                 EnsureAccountDB) - captured as
--                                 `local DB = NS.DB` at the start of
--                                 each function that uses it
--   * NS.PrintNicef             (EbonClearance_Events.lua) - chat output for
--                                 the Process panel's status lines
--   * NS.Delay                  (EbonClearance_Events.lua) - timer helper
--   * NS.IsAddonEnabledForChar  (EbonClearance_Events.lua) - per-character
--                                 enable gate
--
-- Two cached values resolved at file load:
--   * EC_compCache.PICK_LOCK_NAME runs GetSpellInfo(1804) once. If
--     GetSpellInfo returns nil at file-load time (rare; the spell DB
--     should be populated by then on 3.3.5a) the UNIT_SPELLCAST_SUCCEEDED
--     handler in EbonClearance_Events.lua re-resolves on first nil.

local NS = select(2, ...)
local EC_compCache = NS.compCache

local GetItemInfo = GetItemInfo
local GetContainerItemID = GetContainerItemID
local GetContainerItemLink = GetContainerItemLink
local GetContainerNumSlots = GetContainerNumSlots
local IsSpellKnown = IsSpellKnown
local IsEquippableItem = IsEquippableItem
local GetSpellInfo = GetSpellInfo

-- Set-membership helper. Captures the canonical NS.IsInSet (defined in
-- EbonClearance_Core.lua) into a file-local upvalue so per-call cost
-- stays at one local read. Test 65 in tests/test_perf_guardrails.lua
-- locks the bind-where-used invariant per file.
local IsInSet = NS.IsInSet

-- ---------------------------------------------------------------------------
-- v2.22.0 Process Bags helpers
-- ---------------------------------------------------------------------------
-- Three profession spells let players turn eligible bag items into
-- crafting materials: Disenchant (13262, requires Enchanting),
-- Milling (51005, requires Inscription), Prospecting (31252,
-- requires Jewelcrafting). The Process Bags panel scans bags and
-- offers a secure-button macro to cast the appropriate spell on one
-- queued item at a time. Eligibility caches are per-itemID because
-- the underlying property is stable. Spell IDs and helpers all hung
-- off EC_compCache to stay under Lua 5.1's 200-locals cap.

EC_compCache.SPELL_DISENCHANT = 13262
EC_compCache.SPELL_MILLING = 51005
EC_compCache.SPELL_PROSPECTING = 31252
-- v2.25.0: rogue Pick Lock. One spell handles every lockable
-- container; the cast may still fail if the lockbox's required
-- lockpicking skill exceeds the player's. We don't gate on skill
-- here - just on knowing the spell - and let the standard Blizzard
-- "Lock is too difficult" error surface if the skill is short.
-- Engineering Lockpick items / consumable lockpicks are deliberately
-- out of scope; they need a different interaction model (right-click
-- the item, then click the box) that doesn't fit the secure-button
-- macrotext workflow.
EC_compCache.SPELL_PICK_LOCK = 1804
-- v2.25.0: cached spell name for UNIT_SPELLCAST_SUCCEEDED matching.
-- arg2 of that event is a localised spell name string, not an ID, so
-- we resolve once at load and compare strings on each cast event.
-- GetSpellInfo may return nil if called before the spell DB is ready;
-- the handler also defensively re-resolves on first nil. Cached on
-- EC_compCache to stay under Lua 5.1's 200-locals cap.
EC_compCache.PICK_LOCK_NAME = (GetSpellInfo and GetSpellInfo(1804)) or "Pick Lock"

-- v2.62.0: per-skill Process Bags toggles. Map each spell-gated mode to its
-- spell so the panel can show a toggle only for skills this character has.
-- Convert has no spell (its OnUse item drives the conversion), so its
-- availability is "is a convertible in the bags right now" - hasConvertiblesInBags.
EC_compCache.PROCESS_MODE_SPELL = {
    Disenchant = EC_compCache.SPELL_DISENCHANT,
    Mill = EC_compCache.SPELL_MILLING,
    Prospect = EC_compCache.SPELL_PROSPECTING,
    Lockpick = EC_compCache.SPELL_PICK_LOCK,
}

-- True if any bag slot holds a convertible mote/crystallized item, regardless
-- of stack size or whether Convert is enabled. Early-exits on first hit; the
-- check is a table lookup (canConvertElemental), no tooltip scan.
-- v2.62.1: memoised per frame (GetTime is frame-constant on 3.3.5a). The
-- per-skill toggle layout asks for Convert availability on every panel
-- refresh, which otherwise repeated this full bag walk alongside the
-- buildProcessSummary walk in the same refresh. Bags cannot change within
-- a frame, so a same-frame memo is exact.
local convertMemoAt, convertMemoVal
function EC_compCache.hasConvertiblesInBags()
    local now = GetTime()
    if convertMemoAt == now then
        return convertMemoVal
    end
    local found = false
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID and EC_compCache.canConvertElemental(itemID) then
                found = true
                break
            end
        end
        if found then
            break
        end
    end
    convertMemoAt, convertMemoVal = now, found
    return found
end

-- Can THIS character perform `mode` at all (independent of the on/off toggle
-- and of stack counts)? Skills gate on IsSpellKnown; Convert gates on bag
-- contents. Used only for deciding which toggle checkboxes to show.
function EC_compCache.processModeAvailable(mode)
    if mode == "Convert" then
        return EC_compCache.hasConvertiblesInBags()
    end
    local sid = EC_compCache.PROCESS_MODE_SPELL[mode]
    return (sid and IsSpellKnown and IsSpellKnown(sid)) and true or false
end

-- v2.41.2: equippable slots that LOOK like DE candidates (pass
-- IsEquippableItem + quality 2-4) but the server rejects with
-- "Item cannot be disenchanted". The 9th GetItemInfo return is
-- equipLoc, an unlocalised constant - safe to compare across
-- locales. A real player report (green Traveler's Backpack
-- queued for DE on v2.41.x, server refused the cast) led to
-- this blacklist. INVTYPE_BAG / INVTYPE_QUIVER cover regular
-- and ammo bags; INVTYPE_TABARD / INVTYPE_BODY / INVTYPE_AMMO
-- are belt-and-braces for custom-server green-quality tabards
-- / shirts / ammo that could otherwise slip through.
local NON_DE_EQUIP_LOCS = {
    INVTYPE_BAG = true,
    INVTYPE_QUIVER = true,
    INVTYPE_TABARD = true,
    INVTYPE_BODY = true,
    INVTYPE_AMMO = true,
}

function EC_compCache.canDisenchant(itemID)
    if not itemID then
        return false
    end
    if not IsSpellKnown or not IsSpellKnown(EC_compCache.SPELL_DISENCHANT) then
        return false
    end
    if not IsEquippableItem or not IsEquippableItem(itemID) then
        return false
    end
    local _, _, quality, _, _, _, _, _, equipLoc = GetItemInfo(itemID)
    if not quality then
        return false
    end
    -- v2.41.2: exclude equippable slots that aren't actually
    -- disenchantable. Bags pass IsEquippableItem because they go
    -- in bag slots; the server still refuses Disenchant on them.
    if equipLoc and NON_DE_EQUIP_LOCS[equipLoc] then
        return false
    end
    -- DE works on Uncommon (2) through Epic (4). Quality 5+ (Legendary,
    -- Artifact, Heirloom) is treated as not-disenchantable.
    return quality >= 2 and quality <= 4
end

-- Strip WoW color codes (|cFFRRGGBBxxx|r) and trim outer whitespace
-- from a tooltip line so a bare-equality compare against a marker
-- ("Millable" / "Prospectable") matches even when the client renders
-- the line yellow via inline color codes. The original byte-exact
-- compare silently broke Mill / Prospect detection on Project Ebonhold
-- because the live tooltip line is `|cFFFFFF00Prospectable|r`, not
-- bare `Prospectable`. itemHasChanceOnHit (EbonClearance_Protection.lua)
-- uses a similar pattern-tolerant approach via lineLooksLikeChanceProc.
local function normaliseTooltipLine(s)
    if not s then
        return ""
    end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return s:match("^%s*(.-)%s*$") or s
end

-- Unified Mill / Prospect classifier. Scans the item's tooltip ONCE
-- for both ITEM_MILLABLE and ITEM_PROSPECTABLE markers and caches the
-- classification per itemID. Returns one of "Mill" / "Prospect" / "none".
--
-- v2.36.x fix for the cache-poisoning bug that hid Prospect detection:
-- the previous design had canMill and canProspect call a single-marker
-- scan helper that wrote `processCache[itemID] = "none"` on miss. For
-- a player with both Inscription and Jewelcrafting, the bag walk hit
-- canMill FIRST for every item; ore failed the Millable check and got
-- cached as "none"; canProspect saw "none" and returned false without
-- ever scanning for Prospectable. Items in the bag like Mageroyal
-- worked (Millable matched on canMill) but Copper Ore was invisible
-- to the Prospect section.
--
-- An item can only carry one of the two markers in 3.3.5a (Inscription
-- mills herbs; Jewelcrafting prospects ore; there is no item type that
-- carries both), so a tri-state cache value is sufficient.
function EC_compCache.processTooltipHasLine(bag, slot, itemID)
    if not bag or not slot or not itemID then
        return "none"
    end
    local cached = EC_compCache.processCache[itemID]
    if cached then
        return cached
    end
    -- v2.38.3: SetOwner-before-SetBagItem invariant via the shared
    -- helper. Direct SetBagItem calls were silently no-op'ing whenever
    -- the scan frame lost ownership mid-session, and the resulting
    -- empty scan got cached as "none" until /reload.
    EC_compCache.scanBagItem(bag, slot)
    local millMarker = ITEM_MILLABLE or "Millable"
    local prospectMarker = ITEM_PROSPECTABLE or "Prospectable"
    local result = "none"
    for i = 1, 30 do
        local line = EC_compCache.scanLines[i]
        if not line then
            break
        end
        local txt = normaliseTooltipLine(line:GetText())
        if txt == millMarker then
            result = "Mill"
            break
        elseif txt == prospectMarker then
            result = "Prospect"
            break
        end
    end
    EC_compCache.processCache[itemID] = result
    return result
end

function EC_compCache.canMill(bag, slot, itemID)
    if not IsSpellKnown or not IsSpellKnown(EC_compCache.SPELL_MILLING) then
        return false
    end
    if not itemID then
        return false
    end
    return EC_compCache.processTooltipHasLine(bag, slot, itemID) == "Mill"
end

function EC_compCache.canProspect(bag, slot, itemID)
    if not IsSpellKnown or not IsSpellKnown(EC_compCache.SPELL_PROSPECTING) then
        return false
    end
    if not itemID then
        return false
    end
    return EC_compCache.processTooltipHasLine(bag, slot, itemID) == "Prospect"
end

-- v2.25.0: lockpick eligibility. Unlike Mill/Prospect/DE eligibility,
-- the "is this lockable" state is per-INSTANCE (a container is either
-- currently locked or already opened), so we don't cache. The LOCKED
-- tooltip marker is the same locale string EC_IsOpenable uses to
-- exclude locked containers from the auto-open driver, so an item
-- that fails EC_IsOpenable's LOCKED gate is exactly the one that
-- belongs in Lockpick mode.
function EC_compCache.canPickLock(bag, slot)
    if not IsSpellKnown or not IsSpellKnown(EC_compCache.SPELL_PICK_LOCK) then
        return false
    end
    if not bag or not slot then
        return false
    end
    local _, count, locked = GetContainerItemInfo(bag, slot)
    if not count or count <= 0 then
        return false
    end
    -- Skip slots the engine has flagged locked (mid-pickup, mid-cast).
    -- The Pick Lock cast would fail against a locked-state slot anyway,
    -- and including them would cause the cursor to jitter during the
    -- cast resolution window (same locked-slot story as Mill/Prospect).
    if locked then
        return false
    end
    -- v2.38.3: SetOwner-before-SetBagItem via the shared helper. See
    -- EbonClearance_Events.lua's scanBagItem comment for the rationale.
    EC_compCache.scanBagItem(bag, slot)
    for i = 1, 30 do
        local line = EC_compCache.scanLines[i]
        if not line then
            break
        end
        local txt = line:GetText()
        if txt == LOCKED then
            return true
        end
    end
    return false
end

-- Tooltip-scan to check Soulbound status. The DE quality cap and
-- soulbound-include settings are applied here so the returned list
-- already respects user prefs.
function EC_compCache.processIsSoulbound(bag, slot)
    -- v2.38.3: SetOwner-before-SetBagItem via the shared helper.
    EC_compCache.scanBagItem(bag, slot)
    for i = 1, 30 do
        local line = EC_compCache.scanLines[i]
        if not line then
            break
        end
        local txt = line:GetText()
        if txt == ITEM_SOULBOUND then
            return true
        end
    end
    return false
end

-- Build an ordered list of process-eligible entries for the panel UI
-- and the cast-button rearm. Returns an array of entries; each entry:
--   { bag, slot, itemID, link, count, mode, spellName, perCast, casts }
-- Sorted: Disenchant first (by quality desc), then Mill, then Prospect.
-- Honours: Keep List exclude, currently-equipped exclude, ignored
-- list exclude, soulbound-toggle (DE only), DE quality cap.
function EC_compCache.buildProcessSummary()
    local DB = NS.DB
    local ADB = NS.ADB
    local results = {}
    if not DB then
        return results
    end
    local maxQ = DB.processMaxDEQuality or 4
    local includeSB = DB.processIncludeSoulbound == true
    local ignored = DB.processIgnored or {}
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            local link = GetContainerItemLink(bag, slot)
            local _, count = GetContainerItemInfo(bag, slot)
            -- Intentionally not filtering on `locked` here: a slot is
            -- briefly locked during the half-second a /cast on it
            -- resolves, and excluding it would make the BAG_UPDATE
            -- driven rearm lose the armedItemString lookup, fall
            -- through to armedMode, and jump the cursor to a different
            -- entry (then jump back once the slot unlocks). Keeping
            -- locked slots in the list keeps the cursor stable across
            -- the cast window. The /use macro would fail harmlessly
            -- against a locked slot if the player click landed there
            -- anyway.
            if itemID and link and count and count > 0 then
                local itemString = link:match("item[%-?%d:]+")
                local skip = false
                if itemString and ignored[itemString] then
                    skip = true
                end
                if not skip and IsInSet(DB.blacklist, itemID) then
                    skip = true
                end
                if not skip and IsEquippedItem and IsEquippedItem(itemID) then
                    skip = true
                end
                -- v2.26.0: chance-on-hit protection extends to Process
                -- Bags. An item carrying a `Chance on hit:` proc is
                -- hidden from the DE / Mill / Prospect list until the
                -- player marks its itemID via Alt+Right-Click ->
                -- "Allow Sell". Same gate the auto-rule sell sweep
                -- uses, applied here too so the user can't
                -- accidentally DE / mill a weapon whose proc they
                -- might still want to extract.
                if
                    not skip
                    and DB.protectChanceOnHitItems
                    and EC_compCache.itemHasChanceOnHit(bag, slot, itemID)
                    and not (ADB.allowedItems and ADB.allowedItems[itemID])
                then
                    skip = true
                end
                if not skip then
                    local mode, spellName, perCast
                    -- One GetItemInfo read for quality, reused by the
                    -- Disenchant gate and the result row below.
                    local _, _, quality = GetItemInfo(itemID)
                    if DB.processEnabledModes.Disenchant ~= false and EC_compCache.canDisenchant(itemID) then
                        -- v2.23.0: same dupe gate as the sell / delete
                        -- chain. v2.27.0: also honour the unified
                        -- ADB.allowedItems override so a user-marked
                        -- affix item is DE-eligible from Process Bags.
                        local affixGuarded = false
                        if quality and quality >= 3 and DB.protectAffixedRareItems then
                            local affix = EC_compCache.bagSlotAffixData and EC_compCache.bagSlotAffixData(bag, slot)
                            if affix then
                                local affixKey = affix.description
                                    and EC_compCache.normaliseAffixDesc(affix.description)
                                local manualAllow = affixKey and ADB.allowedAffixes and ADB.allowedAffixes[affixKey]
                                -- v2.59.4 fix (Serv report - Epic set items
                                -- with known ranked affixes were WILL SELL
                                -- at the vendor but hidden from Process
                                -- Bags DE): route ownership through the
                                -- shared EC_compCache.playerOwnsAffix
                                -- helper (Protection.lua) so this gate
                                -- checks description OR rank OR family in
                                -- lockstep with EC_IsSellable's dupe gate.
                                -- Pre-fix, this branch only checked
                                -- description + unranked-family, missing
                                -- the ranked case that v2.35.1 added to
                                -- Tooltip.lua and EC_IsSellable. Result
                                -- was a mirror-drift: sell path released
                                -- via playerHasAffixRank, Process Bags DE
                                -- did not, so the item was more
                                -- restrictively protected here than at
                                -- the vendor.
                                local ownsAffix = EC_compCache.playerOwnsAffix
                                    and EC_compCache.playerOwnsAffix(affix)
                                    or false
                                local autoDupe = DB.affixAllowExactDupes and ownsAffix
                                -- v2.44.0: rank-floor opt-out. Mirrors
                                -- the sell-path + delete-path so an
                                -- affixed item below the user's
                                -- chosen rank is also free to be
                                -- disenchanted from Process Bags.
                                local rankBelow = DB.affixMinSellRank
                                    and DB.affixMinSellRank > 0
                                    and affix.rank
                                    and affix.rank < DB.affixMinSellRank
                                affixGuarded = not (manualAllow or autoDupe or rankBelow)
                            end
                        end
                        if quality and quality <= maxQ and not affixGuarded then
                            if includeSB or not EC_compCache.processIsSoulbound(bag, slot) then
                                mode = "Disenchant"
                                spellName = GetSpellInfo and GetSpellInfo(EC_compCache.SPELL_DISENCHANT) or "Disenchant"
                                perCast = 1
                            end
                        end
                    elseif DB.processEnabledModes.Mill ~= false and EC_compCache.canMill(bag, slot, itemID) then
                        if count >= 5 then
                            mode = "Mill"
                            spellName = GetSpellInfo and GetSpellInfo(EC_compCache.SPELL_MILLING) or "Milling"
                            perCast = 5
                        end
                    elseif DB.processEnabledModes.Prospect ~= false and EC_compCache.canProspect(bag, slot, itemID) then
                        if count >= 5 then
                            mode = "Prospect"
                            spellName = GetSpellInfo and GetSpellInfo(EC_compCache.SPELL_PROSPECTING) or "Prospecting"
                            perCast = 5
                        end
                    elseif DB.processEnabledModes.Lockpick ~= false and EC_compCache.canPickLock(bag, slot) then
                        -- v2.25.0: rogue Pick Lock. perCast = 1 (one
                        -- cast unlocks one container; the container
                        -- itself stays in the bag with a Right Click
                        -- to Open state that the existing auto-open
                        -- driver picks up on the next BAG_UPDATE).
                        mode = "Lockpick"
                        spellName = GetSpellInfo and GetSpellInfo(EC_compCache.SPELL_PICK_LOCK) or "Pick Lock"
                        perCast = 1
                    elseif DB.processEnabledModes.Convert ~= false and EC_compCache.canConvertElemental(itemID) then
                        -- v2.44.9: Crystallized / Mote condensing.
                        -- No spell to cast - the lower-tier item's
                        -- OnUse triggers the server-side conversion
                        -- when used via /use bag slot. perCast = 10
                        -- so casts = floor(count / 10) reads "1 cast
                        -- = 1 Eternal/Primal" for the player.
                        -- spellName stays nil; rearmProcessButton
                        -- generates a /use-only macro when nil.
                        if count >= 10 then
                            mode = "Convert"
                            spellName = nil
                            perCast = 10
                        end
                    end
                    if mode then
                        results[#results + 1] = {
                            bag = bag,
                            slot = slot,
                            itemID = itemID,
                            itemString = itemString,
                            link = link,
                            count = count,
                            mode = mode,
                            spellName = spellName,
                            perCast = perCast,
                            casts = math.floor(count / perCast),
                            quality = quality or 1,
                        }
                    end
                end
            end
        end
    end
    -- Sort: Disenchant first, then Mill, then Prospect, then
    -- Lockpick. Within mode: DE by quality desc (Epic before Rare
    -- before Uncommon), Mill / Prospect / Lockpick alphabetically by
    -- item name.
    --
    -- Pre-compute names onto each entry so the comparator runs O(1)
    -- per compare. Without the cache, table.sort calls the comparator
    -- O(N log N) times and each call would hit GetItemInfo twice -
    -- compounding overhead per BAG_UPDATE-driven rebuild.
    for _, e in ipairs(results) do
        e.name = (GetItemInfo(e.itemID)) or ""
    end
    local modeOrder = { Disenchant = 1, Mill = 2, Prospect = 3, Lockpick = 4, Convert = 5 }
    table.sort(results, function(a, b)
        if a.mode ~= b.mode then
            return modeOrder[a.mode] < modeOrder[b.mode]
        end
        if a.mode == "Disenchant" then
            if a.quality ~= b.quality then
                return a.quality > b.quality
            end
        end
        return a.name < b.name
    end)
    return results
end

-- ---------------------------------------------------------------------------
-- v2.44.9 Crystallized / Mote condensing (Process Bags Convert mode).
-- ---------------------------------------------------------------------------
-- Lower-tier elemental reagents convert 10:1 to their upper-tier form via
-- a vanilla WoW OnUse effect: right-click a stack of 10 Crystallized Fire
-- (or Mote of Fire) and the server consumes 10 and grants 1 Eternal Fire
-- (or Primal Fire). No profession requirement.
--
-- EC-TRAP: an earlier draft of this feature tried to auto-fire from the
-- BAG_UPDATE debounce. That hit WoW 3.3.5a's secure-execution protection:
-- UseContainerItem on items whose OnUse casts a spell is taint-restricted
-- to hardware-event-driven secure call chains. The popup "EbonClearance
-- has been blocked from an action only available to the Blizzard UI"
-- fires when an insecure Lua context tries this. The Process Bags engine
-- already does the secure-button dance (SecureActionButton + macrotext
-- triggered by a player click), so Convert lives there as a 5th process
-- mode alongside Disenchant / Mill / Prospect / Lockpick - one click per
-- stack. If a future patch tries to "make Convert automatic" via the
-- debounce, expect the same security popup; the only way to fully auto
-- is a secure hardware event the addon can't synthesise.
--
-- itemIDs:
--   * WotLK Crystallized 37700-37705 (six elemental schools).
--   * TBC Motes 22572-22578 (seven schools - Air/Earth/Fire/Life/Mana/
--     Shadow/Water; Mote of Mana has no WotLK equivalent).
local CONVERTIBLE_ELEMENTALS = {
    -- WotLK Crystallized -> Eternal
    [37700] = true, -- Crystallized Air     -> Eternal Air
    [37701] = true, -- Crystallized Earth   -> Eternal Earth
    [37702] = true, -- Crystallized Fire    -> Eternal Fire
    [37703] = true, -- Crystallized Shadow  -> Eternal Shadow
    [37704] = true, -- Crystallized Life    -> Eternal Life
    [37705] = true, -- Crystallized Water   -> Eternal Water
    -- TBC Motes -> Primals
    [22572] = true, -- Mote of Air          -> Primal Air
    [22573] = true, -- Mote of Earth        -> Primal Earth
    [22574] = true, -- Mote of Fire         -> Primal Fire
    [22575] = true, -- Mote of Life         -> Primal Life
    [22576] = true, -- Mote of Mana         -> Primal Mana
    [22577] = true, -- Mote of Shadow       -> Primal Shadow
    [22578] = true, -- Mote of Water        -> Primal Water
}

EC_compCache.CONVERTIBLE_ELEMENTALS = CONVERTIBLE_ELEMENTALS

-- Eligibility predicate for the Convert mode. Mirrors canMill / canProspect
-- in shape: returns true when the item is a known lower-tier elemental
-- AND the count gate is met (10 per conversion). The list-veto + ignored
-- + equipped + chance-on-hit gates already live in buildProcessSummary
-- above this branch; we don't duplicate them here.
function EC_compCache.canConvertElemental(itemID)
    return itemID and CONVERTIBLE_ELEMENTALS[itemID] == true
end

