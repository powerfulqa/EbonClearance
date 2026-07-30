-- EbonClearance_Decision - the single sell/keep decision core.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 1 of the decision-classifier plan
-- (docs/specs/2026-07-29-decision-classifier-design.md; CODE_REVIEW audit
-- item 6 / competitive-review Tier A1). Two layers:
--
--   * NS.Decision.sell(ctx) - the PURE core. Reads ONLY the ctx table
--     (plain values + caller-supplied thunks). No WoW API, no DB, no
--     EC_compCache, no locale reads. Loadable under stock lua5.1, which
--     is what makes tests/test_decision.lua the addon's first RUNTIME
--     coverage of the sell logic.
--   * NS.Decision.buildCtx(bag, slot, junkOnly) - the adapter. Performs
--     every WoW / DB / cache read, reusing the existing cached accessors
--     (getBindType, bagSlotAffixData, itemHasChanceOnHit, ...) so scan
--     cost and lazy-fill behaviour are unchanged. Expensive predicates
--     ride as THUNKS so the core only pays for them on the branches that
--     need them - the same short-circuit profile EC_IsSellable had.
--
-- The core's logic is a faithful transcription of EC_IsSellable at
-- v2.70.0 (the vendor engine is ground truth). The long per-version
-- rationale comments stay in git history on EbonClearance_Events.lua;
-- the load-bearing EC-TRAPs and invariants move here WITH the logic.
--
-- Verdicts: "sell" | "keep" | "none".
--   "sell" - a positive signal fired and survived every veto.
--   "keep" - an explicit protection refused it (the reason token says
--            which one).
--   "none" - nothing matched (or the slot is empty/locked/unusable).
-- Tokens are append-only once shipped; renderers must tolerate unknown
-- tokens with a neutral fallback.

local NS = select(2, ...)

-- Cached API upvalues (engine-file convention). Only the adapter uses
-- them; the core reads ctx exclusively.
local GetContainerItemID = GetContainerItemID
local GetContainerItemInfo = GetContainerItemInfo
local GetItemInfo = GetItemInfo
local IsEquippedItem = IsEquippedItem

-- The shared cache table is created in Core (loads first), so binding it
-- at file scope is safe; its MEMBERS are added later by Events /
-- Protection, so every member access below still resolves at call time.
local EC_compCache = NS.compCache

local Decision = {}
NS.Decision = Decision

-- ---------------------------------------------------------------------------
-- Pure core.
-- ---------------------------------------------------------------------------
-- INVARIANT (EC-TRAP): grey items (quality == 0) with a positive sell
-- price ALWAYS match via isJunk, independent of whitelist / quality-rule
-- settings. Do NOT combine the isJunk / qualityPass / whitelistPass
-- passes into "one cleaner check" - that silently breaks the
-- grey-always-sold guarantee (ADDON_GUIDE "Grey items are always sold").
-- The runtime fixtures in tests/test_decision.lua pin this for the first
-- time.
function Decision.sell(ctx)
    if not ctx or not ctx.itemID then
        return "none", "empty"
    end
    if not ctx.count or ctx.count <= 0 or ctx.locked then
        return "none", "locked"
    end
    local quality = ctx.quality
    local junkOnly = ctx.junkOnly
    local hasSellPrice = ctx.sellPrice and ctx.sellPrice > 0
    local isJunk = (quality ~= nil) and (quality == 0) and hasSellPrice
    local whitelistPass = not junkOnly
        and hasSellPrice
        and (ctx.whitelistedChar or ctx.whitelistedAccount)

    -- Per-rarity rules (v2.4.0+). cap == 0 -> sell everything of the
    -- rarity; cap > 0 -> STRICT: only equippable items (non-empty
    -- equipLoc, visible iLvl) at or under the cap.
    local qualityPass = false
    local rule = ctx.qualityRule
    if not junkOnly and hasSellPrice and quality and quality >= 1 and quality <= 4 and rule and rule.enabled then
        if rule.useEquippedILvl then
            -- v2.12.0 dynamic-cap mode: compare against the player's
            -- equipped item (empty-slot guard etc. live in the thunk).
            if ctx.downgradeVsEquipped() then
                qualityPass = true
            end
        else
            local cap = rule.maxILvl or 0
            local hasVisibleILvl = ctx.equipLoc and ctx.equipLoc ~= "" and ctx.ilvl and ctx.ilvl > 0
            if cap == 0 then
                qualityPass = true
            elseif hasVisibleILvl and ctx.ilvl <= cap then
                qualityPass = true
            end
        end
        -- v2.10.0 bind filter: no-bind-line items read "any" and are
        -- excluded by both "boe" and "bop" ("Sell BoE only" must not
        -- sweep up reagents).
        if qualityPass then
            local bindFilter = rule.bindFilter or "any"
            if bindFilter ~= "any" and bindFilter ~= ctx.bindType() then
                qualityPass = false
            end
        end
    end
    -- v2.13.x quest-item safety net: vetoes the auto-rule sweep only;
    -- explicit Sell List entries override (the whitelist IS user intent).
    if qualityPass and ctx.isQuestItem then
        qualityPass = false
    end
    -- Baseline profession-tool safety net: same narrowing; per-item
    -- Allow Sell (allowedItem) bypasses.
    if qualityPass and ctx.baselineProtected and not ctx.allowedItem then
        qualityPass = false
    end

    -- v2.44.0: affix-rank floor as a STANDALONE sell signal (rank below
    -- floor sells on its own). v2.48.1: hasSellPrice-gated (the vendor
    -- refuses zero-value items). v2.49.0: junkOnly-gated (merchant mode).
    local affixForRank = (quality and quality >= 3) and ctx.affixData() or nil
    local affixRankPass = not junkOnly
        and hasSellPrice
        and ctx.affixMinSellRank
        and ctx.affixMinSellRank > 0
        and affixForRank
        and affixForRank.rank
        and affixForRank.rank < ctx.affixMinSellRank
        or false
    -- v2.66.0: BoE-keep for the rank-floor path. EC-TRAP: the trace and
    -- tooltip apply the same gate - Stage 2/3 of the classifier plan
    -- retires the paired edit; until then they render from this core's
    -- token so drift is structural, not manual.
    if affixRankPass and ctx.keepBoeBelowRankFloor and ctx.bindType() ~= "bop" then
        affixRankPass = false
    end
    -- v2.44.0: "sell affixes you already have" as a standalone signal.
    local autoDupePass = false
    if not junkOnly and hasSellPrice and ctx.affixAllowExactDupes and affixForRank then
        local descKnown = affixForRank.description and ctx.affixDescKnown(affixForRank.description)
        local rankKnown = (not descKnown)
            and affixForRank.name
            and affixForRank.rank
            and ctx.affixRankKnown(affixForRank.name, affixForRank.rank)
        -- v2.45.0: family fallback for UNRANKED affixes only.
        local familyKnown = (not descKnown)
            and (not rankKnown)
            and (not affixForRank.rank)
            and affixForRank.name
            and ctx.affixFamilyKnown(affixForRank.name)
        autoDupePass = (descKnown or rankKnown or familyKnown) and true or false
        -- v2.47.0 bind-type split: with "keep BoE dupes" on, only
        -- SOULBOUND owned dupes sell. EC-TRAP: the affix-protection
        -- veto-release below applies the SAME gate - one core now
        -- guarantees the lockstep the old three mirrors maintained by
        -- hand.
        if autoDupePass and ctx.keepBoeAffixDupes and ctx.bindType() ~= "bop" then
            autoDupePass = false
        end
    end
    -- v2.57.2 SAFETY (the near item-loss fix): the rarity rule's iLvl
    -- cap is a HARD ceiling for the affix sell paths. EC-TRAP: this is
    -- the shared affixSaleWithinCeiling gate; the thunk routes to the
    -- same helper every mirror uses.
    if (affixRankPass or autoDupePass) and not ctx.saleWithinCeiling() then
        affixRankPass = false
        autoDupePass = false
    end

    -- Sell Known Recipes: learned profession recipes only (tomeKind ==
    -- "Recipe"); per-quality enable + per-quality bind filter. Overrides
    -- the tome veto below for exactly this case.
    local recipePass = false
    if not junkOnly
        and hasSellPrice
        and ctx.sellKnownRecipes
        and quality
        and quality >= 1
        and quality <= 4
        and ctx.sellKnownRecipeQuality
        and ctx.isTome()
        and ctx.tomeKind() == "Recipe"
        and ctx.knowsTomeSpell()
    then
        recipePass = true
        local recipeBindFilter = ctx.recipeBindFilter or "any"
        if recipeBindFilter ~= "any" and recipeBindFilter ~= ctx.bindType() then
            recipePass = false
        end
    end

    -- v2.49.0: "Sell known chance-on-hit procs" as a standalone signal.
    local knownProcPass = false
    if not junkOnly
        and hasSellPrice
        and ctx.sellChanceOnHitKnown
        and ctx.protectChanceOnHitItems
        and ctx.hasChanceOnHit()
    then
        local procLine = ctx.chanceProcLine()
        if procLine and ctx.hasExtractedProc(procLine) then
            knownProcPass = true
        end
    end

    if not (isJunk or qualityPass or whitelistPass or affixRankPass or autoDupePass or recipePass or knownProcPass) then
        return "none", "noSignal"
    end
    if ctx.equipped then
        return "keep", "equipped"
    end
    if ctx.blacklisted then
        return "keep", "blacklist"
    end

    -- v2.19.0+ PE affix protection (Rare/Epic). Releases: affix-keyed
    -- Allow Sell (manualAllow), owned dupe with the dupes toggle
    -- (autoDupe, same BoE gate as autoDupePass - EC-TRAP lockstep now
    -- structural), or rank below the floor (rankBelow).
    if (whitelistPass or qualityPass) and ctx.protectAffixedRareItems and quality and quality >= 3 then
        local affix = affixForRank
        if affix then
            local manualAllow = affix.description and ctx.manualAffixAllow(affix.description)
            local descKnown = affix.description and ctx.affixDescKnown(affix.description) or false
            local rankKnown = (not descKnown)
                and affix.name
                and affix.rank
                and ctx.affixRankKnown(affix.name, affix.rank)
                or false
            local familyKnown = (not descKnown)
                and (not rankKnown)
                and (not affix.rank)
                and affix.name
                and ctx.affixFamilyKnown(affix.name)
                or false
            local autoDupe = ctx.affixAllowExactDupes and (descKnown or rankKnown or familyKnown)
            if autoDupe and ctx.keepBoeAffixDupes and ctx.bindType() ~= "bop" then
                autoDupe = false
            end
            local rankBelow = ctx.affixMinSellRank
                and ctx.affixMinSellRank > 0
                and affix.rank
                and affix.rank < ctx.affixMinSellRank
            if not (manualAllow or autoDupe or rankBelow) then
                return "keep", "affixProtected", {
                    affixName = affix.name,
                    affixRank = affix.rank,
                    owned = (descKnown or rankKnown or familyKnown) and true or false,
                }
            end
        end
    end

    -- v2.20.0+ chance-on-hit protection: auto-rule sweeps only
    -- (whitelistPass exempt); weapons only (v2.60.0 - the Anvil refuses
    -- non-weapon extraction, so protecting a trinket just wedges it);
    -- released by per-item Allow Sell or knownProcPass. The protection
    -- CLEARS the auto signals; the exit gate below decides.
    local clearedByProc = false
    if (qualityPass or affixRankPass or autoDupePass or recipePass)
        and ctx.protectChanceOnHitItems
        and ctx.hasChanceOnHit()
        and ctx.isExtractableWeaponSlot()
    then
        if not ctx.allowedItem and not knownProcPass then
            qualityPass = false
            affixRankPass = false
            autoDupePass = false
            recipePass = false
            clearedByProc = true
        end
    end

    -- Tome protection. Releases: whitelistPass (v2.51.2/v2.59.10 - Sell
    -- List is user intent, including the both-signals case), recipePass
    -- (Sell Known Recipes carve-out), per-item Allow Sell. EC-TRAP: this
    -- is the condition shape all three mirrors must share; from Stage 2
    -- onward they render from this core.
    if qualityPass
        and not whitelistPass
        and not recipePass
        and (ctx.protectAllTomes or ctx.protectUnlearnedTomes)
        and ctx.isTome()
    then
        if not ctx.allowedItem then
            if ctx.protectAllTomes then
                return "keep", "tomeProtected"
            elseif ctx.protectUnlearnedTomes and not ctx.knowsTomeSpell() then
                return "keep", "tomeUnlearned"
            end
        end
    end

    -- Exit-gate recheck. EC-TRAP: keep affixRankPass / autoDupePass in
    -- this recheck - they are positive signals; trimming them "to match
    -- the original v2.20.x shape" was the v2.44.1 bug.
    if not (isJunk or qualityPass or whitelistPass or affixRankPass or autoDupePass or recipePass or knownProcPass) then
        if clearedByProc then
            return "keep", "chanceonhit"
        end
        return "none", "noSignal"
    end

    -- Winning-signal precedence (most specific / explicit first). Same
    -- vocabulary the Sold History reasons have used since v2.54.x.
    local signal
    if whitelistPass then
        signal = ctx.whitelistedChar and "whitelist_char" or "whitelist_account"
    elseif recipePass then
        signal = "recipe"
    elseif knownProcPass then
        signal = "knownproc"
    elseif affixRankPass then
        signal = "affixrank"
    elseif autoDupePass then
        signal = "autodupe"
    elseif isJunk then
        signal = "junk"
    else
        signal = "quality"
    end
    return "sell", signal, { signal = signal }
end

-- ---------------------------------------------------------------------------
-- Pure core: delete eligibility (v2.71.3, classifier Stage 4).
-- ---------------------------------------------------------------------------
-- "Is this Delete-List item instance destroyable right now?" - a faithful
-- transcription of EC_compCache.deleteListSlotEligible at v2.71.2 (which
-- now delegates here). Returns eligible (boolean), token, fields.
--
-- The v2.50.2 rescue vetoes (the Stickybackpack shirt-loss fix) are the
-- load-bearing part: the auto-mark scans write to deleteList WITHOUT the
-- cross-list conflict guard, so any later Keep intent (Keep List, account
-- Sell List, equipped) must rescue the item at DESTRUCTION time.
-- EC-TRAP: do NOT collapse these vetoes into the affix gate, and note the
-- asymmetry is deliberate: the ACCOUNT Sell List vetoes (a cross-character
-- "I want this" signal) but the character Sell List does not.
--
-- Callers gate on DB.enableDeletion themselves (ctx.enableDeletion is in
-- the snapshot for renderers); this predicate answers eligibility only.
function Decision.deleteEligible(ctx)
    if not ctx or not ctx.itemID then
        return false, "empty"
    end
    if not ctx.onDeleteList then
        return false, "notOnList"
    end
    if ctx.blacklisted then
        return false, "keepList"
    end
    if ctx.whitelistedAccount then
        return false, "sellList"
    end
    if ctx.equipped then
        return false, "equipped"
    end
    if not ctx.count or ctx.count <= 0 or ctx.locked then
        return false, "locked"
    end
    if ctx.protectAffixedRareItems and ctx.quality and ctx.quality >= 3 then
        local affix = ctx.affixData()
        if affix and not ctx.affixDisposable(affix) then
            return false, "affixProtected", { affixName = affix.name, affixRank = affix.rank }
        end
    end
    return true, "deleteList"
end

-- ---------------------------------------------------------------------------
-- Adapters: capture everything the core needs from the live game state.
-- ---------------------------------------------------------------------------
-- Cheap reads are snapshotted; tooltip-backed predicates ride as thunks
-- so the core pays for them only on the branches that need them (the
-- same lazy profile EC_IsSellable had). All EC_compCache accessors keep
-- their own itemID/itemString caches, so repeated thunk calls are cheap.
-- DB / ADB resolve at CALL time (EnsureDB rebinds NS.DB per login; this
-- file loads before Events - the Test 41 load-order trap).
--
-- Two adapters share one snapshot helper so they cannot drift:
--   * buildCtx(bag, slot, junkOnly) - the vendor engine + trace surface;
--     item-instance predicates read the hidden scan tooltip via the
--     bag/slot accessors.
--   * buildTooltipCtx(tooltip, itemID) - the live-tooltip surface
--     (v2.71.2, classifier Stage 3); there is NO bag/slot for a hovered
--     or chat-linked item, so instance predicates read the LIVE tooltip
--     via the liveTooltip* scanners instead. Same per-instance
--     semantics (the hovered tooltip IS the instance).

-- Shared snapshot: itemID-keyed memberships, the settings the core
-- reads, and the affix-ownership thunks (none of these depend on how
-- the item instance is being inspected).
local function EC_fillSharedCtx(ctx, DB, ADB, itemID, quality)
    local IsInSet = NS.IsInSet
    -- memberships / cheap values
    ctx.whitelistedChar = IsInSet(DB.whitelist, itemID)
    ctx.whitelistedAccount = (ADB and IsInSet(ADB.whitelist, itemID)) or false
    ctx.blacklisted = IsInSet(DB.blacklist, itemID)
    ctx.onDeleteList = (DB.deleteList and IsInSet(DB.deleteList, itemID)) and true or false
    ctx.enableDeletion = DB.enableDeletion == true
    ctx.equipped = IsEquippedItem(itemID) and true or false
    ctx.isQuestItem = EC_compCache.isQuestItem(itemID)
    ctx.baselineProtected = (EC_compCache.baselineProtectedIDs and EC_compCache.baselineProtectedIDs[itemID])
            and true
        or false
    ctx.allowedItem = (ADB and ADB.allowedItems and ADB.allowedItems[itemID]) and true or false
    -- settings snapshot
    ctx.qualityRule = (quality and DB.qualityRules) and DB.qualityRules[quality] or nil
    ctx.affixMinSellRank = DB.affixMinSellRank
    ctx.affixAllowExactDupes = DB.affixAllowExactDupes
    ctx.keepBoeAffixDupes = DB.keepBoeAffixDupes
    ctx.keepBoeBelowRankFloor = DB.keepBoeBelowRankFloor
    ctx.sellKnownRecipes = DB.sellKnownRecipes
    ctx.sellKnownRecipeQuality = (quality and DB.sellKnownRecipeQualities) and DB.sellKnownRecipeQualities[quality]
        or false
    ctx.recipeBindFilter = (quality and DB.sellKnownRecipeBindFilter) and DB.sellKnownRecipeBindFilter[quality]
        or "any"
    ctx.sellChanceOnHitKnown = DB.sellChanceOnHitKnown
    ctx.protectChanceOnHitItems = DB.protectChanceOnHitItems
    ctx.protectAffixedRareItems = DB.protectAffixedRareItems
    ctx.protectAllTomes = DB.protectAllTomes
    ctx.protectUnlearnedTomes = DB.protectUnlearnedTomes
    -- itemID-keyed thunks (identical for both adapters)
    function ctx.tomeKind()
        return EC_compCache.tomeKind(itemID)
    end
    function ctx.isExtractableWeaponSlot()
        return EC_compCache.isExtractableWeaponSlot and EC_compCache.isExtractableWeaponSlot(itemID) or false
    end
    function ctx.affixDescKnown(desc)
        return EC_compCache.playerHasAffixDescription and EC_compCache.playerHasAffixDescription(desc) or false
    end
    function ctx.affixRankKnown(name, rank)
        return EC_compCache.playerHasAffixRank and EC_compCache.playerHasAffixRank(name, rank) or false
    end
    function ctx.affixFamilyKnown(name)
        return EC_compCache.playerHasAffixFamily and EC_compCache.playerHasAffixFamily(name) or false
    end
    function ctx.manualAffixAllow(desc)
        local key = EC_compCache.normaliseAffixDesc and EC_compCache.normaliseAffixDesc(desc)
        return (key and ADB and ADB.allowedAffixes and ADB.allowedAffixes[key]) and true or false
    end
    -- Delete-side release policy (v2.47.0): manualAllow OR owned dupe
    -- with a dupe-disposal toggle on OR rank below the floor. ONE shared
    -- definition (EC_compCache.affixDisposable in Events) serves this
    -- thunk and the auto-mark scan, so the two cannot drift.
    function ctx.affixDisposable(affix)
        return EC_compCache.affixDisposable and EC_compCache.affixDisposable(affix) and true or false
    end
end

function Decision.buildCtx(bag, slot, junkOnly)
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB or not EC_compCache then
        return nil
    end
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return { itemID = nil }
    end
    local _, itemCount, locked = GetContainerItemInfo(bag, slot)
    local name, link, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(itemID)
    local ctx = {
        junkOnly = junkOnly and true or false,
        bag = bag,
        slot = slot,
        itemID = itemID,
        count = itemCount,
        locked = locked,
        name = name,
        link = link,
        quality = quality,
        ilvl = ilvl,
        equipLoc = equipLoc,
        sellPrice = sellPrice,
    }
    EC_fillSharedCtx(ctx, DB, ADB, itemID, quality)
    -- instance predicates: hidden scan tooltip via bag/slot accessors
    function ctx.bindType()
        return EC_compCache.getBindType(bag, slot)
    end
    function ctx.downgradeVsEquipped()
        return EC_compCache.isDowngradeVsEquipped(itemID, ilvl, equipLoc)
    end
    function ctx.affixData()
        return EC_compCache.bagSlotAffixData(bag, slot)
    end
    function ctx.saleWithinCeiling()
        return EC_compCache.affixSaleWithinCeiling(quality, ilvl, equipLoc, itemID)
    end
    function ctx.hasChanceOnHit()
        return EC_compCache.itemHasChanceOnHit and EC_compCache.itemHasChanceOnHit(bag, slot, itemID) or false
    end
    function ctx.chanceProcLine()
        return EC_compCache.chanceProcLine and EC_compCache.chanceProcLine(bag, slot, itemID) or nil
    end
    function ctx.hasExtractedProc(procLine)
        return EC_compCache.playerHasExtractedProc and EC_compCache.playerHasExtractedProc(bag, slot, itemID, procLine) or false
    end
    function ctx.isTome()
        return EC_compCache.itemIsTome(bag, slot, itemID)
    end
    function ctx.knowsTomeSpell()
        return EC_compCache.playerKnowsTomeSpell(bag, slot, itemID)
    end
    return ctx
end

-- v2.71.2 (classifier Stage 3): live-tooltip adapter for the tooltip
-- annotation surface. The hovered (or chat-linked) instance has no
-- bag/slot, so the instance predicates read the LIVE tooltip through
-- the same liveTooltip* scanners EC_AnnotateTooltip has always used -
-- the verdict describes what the vendor engine would do to this item
-- as rendered. count=1 / locked=false: a hover is never mid-pickup.
function Decision.buildTooltipCtx(tooltip, itemID)
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB or not EC_compCache or not itemID then
        return nil
    end
    local name, link, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(itemID)
    local ctx = {
        junkOnly = false,
        itemID = itemID,
        count = 1,
        locked = false,
        name = name,
        link = link,
        quality = quality,
        ilvl = ilvl,
        equipLoc = equipLoc,
        sellPrice = sellPrice,
    }
    EC_fillSharedCtx(ctx, DB, ADB, itemID, quality)
    -- instance predicates: the live tooltip IS the instance
    function ctx.bindType()
        return EC_compCache.getBindTypeFromTooltip and EC_compCache.getBindTypeFromTooltip(tooltip, itemID) or "any"
    end
    function ctx.downgradeVsEquipped()
        return EC_compCache.isDowngradeVsEquipped(itemID, ilvl, equipLoc)
    end
    function ctx.affixData()
        return EC_compCache.liveTooltipAffixData and EC_compCache.liveTooltipAffixData(tooltip, itemID) or nil
    end
    function ctx.saleWithinCeiling()
        return EC_compCache.affixSaleWithinCeiling(quality, ilvl, equipLoc, itemID)
    end
    function ctx.hasChanceOnHit()
        return EC_compCache.liveTooltipHasChanceOnHit and EC_compCache.liveTooltipHasChanceOnHit(tooltip, itemID)
            or false
    end
    function ctx.chanceProcLine()
        return EC_compCache.liveTooltipChanceProcLine and EC_compCache.liveTooltipChanceProcLine(tooltip) or nil
    end
    function ctx.hasExtractedProc(procLine)
        return EC_compCache.playerHasExtractedProc and EC_compCache.playerHasExtractedProc(nil, nil, itemID, procLine)
            or false
    end
    function ctx.isTome()
        return EC_compCache.liveTooltipIsTome and EC_compCache.liveTooltipIsTome(tooltip, itemID) or false
    end
    function ctx.knowsTomeSpell()
        return EC_compCache.liveTooltipPlayerKnowsTome and EC_compCache.liveTooltipPlayerKnowsTome(tooltip, itemID)
            or false
    end
    return ctx
end
