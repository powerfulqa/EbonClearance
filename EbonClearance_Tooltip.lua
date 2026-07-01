-- EbonClearance_Tooltip - bag-item tooltip annotation system.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8c of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The tooltip annotation surface that decorates every bag item with a
-- coloured line indicating what EC will do (Will Sell / Protected -
-- Random affix / Protected - Chance on hit / Allowed - Account Sell /
-- etc.). Self-contained UI subsystem hooked at addon load against
-- GameTooltip + ItemRefTooltip.
--
-- Moved into this file:
--   * EC_AnnotateTooltip - the per-tooltip body that walks the same
--     decision chain EC_IsSellable runs and produces a humane status
--     line. Mirrors EC_IsSellable rather than calling it (different
--     output: needs to know WHY, not just yes/no). See
--     docs/CODE_REVIEW.md item 6 for the documented parallel-impl
--     tradeoff.
--   * EC_ClearTooltipFlag - resets the per-tooltip dedupe flag
--     (recipe tooltips fire OnTooltipSetItem twice; the flag prevents
--     duplicate annotation lines).
--   * EC_InstallTooltipHookOnce - installs the OnTooltipSetItem +
--     OnTooltipCleared hooks on GameTooltip + ItemRefTooltip. Exposed
--     as NS.InstallTooltipHookOnce.
--
-- Cross-file dependencies read inline:
--   * NS.compCache (Core) - bagSlotAffixData, itemHasChanceOnHit,
--     normaliseAffixDesc, playerHasAffixDescription, isDowngradeVsEquipped,
--     getEquippedILvl, INVTYPE_SLOTS, baselineProtectedIDs, qualityNames
--   * NS.DB / NS.ADB - captured at function entry
--   * NS.IsAddonEnabledForChar (EbonClearance_Events.lua) - early-out gate
--   * Various WoW globals - ITEM_QUALITY_COLORS, GetItemInfo, etc.

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- Set-membership helper. Captures the canonical NS.IsInSet (defined in
-- EbonClearance_Core.lua); per-call cost is one local read.
local IsInSet = NS.IsInSet

-- Localization lookup. Verdict labels are wrapped at the point they are
-- built; see the EC-TRAP note on statusTag below for why the displayed
-- string can no longer be introspected once it may be translated.
local L = NS.L

-- Allow Sell destination rewrite. Walks the explicit-list precedence
-- chain when a protection (affix / chance-on-hit / tome) has been
-- manually allow-listed and decides what the tooltip should say:
--   * Keep List membership returns currentLine unchanged (the earlier
--     Keep label stays - blacklist wins over Allow Sell).
--   * deleteList -> Will Delete
--   * account whitelist -> Will Sell (your Account List)
--   * character whitelist -> Will Sell (your Character List)
--   * no list claims it -> nil, and the caller picks the fallback
--     ("Override on - add to a list to sell" for Allow Sell prompts,
--     "Will Sell (you have this affix)" for the autoDupe path, etc.).
-- The pre-extraction code duplicated this chain across the affix and
-- tome blocks; centralising removes the drift surface so a future
-- protection rule reuses the same precedence without paired edits.
-- Returns (line, tag). tag is an English token the caller uses for logic
-- (see statusTag below); the line is the localized display string. The
-- blacklist case returns the caller's current line/tag unchanged.
local function destinationLabel(id, currentLine, currentTag)
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB then
        return nil
    end
    if IsInSet(DB.blacklist, id) then
        return currentLine, currentTag
    end
    if IsInSet(DB.deleteList, id) and DB.enableDeletion then
        return "|cff66ccff[EC]|r |cffff4444" .. L["Will Delete"] .. "|r", "willdelete"
    end
    if ADB and ADB.whitelist and IsInSet(ADB.whitelist, id) then
        return "|cff66ccff[EC]|r |cffb6ffb6" .. L["Will Sell (your Account List)"] .. "|r", "willsell"
    end
    if IsInSet(DB.whitelist, id) then
        return "|cff66ccff[EC]|r |cffb6ffb6" .. L["Will Sell (your Character List)"] .. "|r", "willsell"
    end
    return nil
end

-- Tooltip annotation. Adds a coloured line indicating whether EbonClearance
-- will sell, protect, or delete the hovered item. Hooked once on addon load
-- against GameTooltip and ItemRefTooltip (chat-linked items use the latter).
--
-- Dedupe: recipe tooltips fire OnTooltipSetItem twice (once for the recipe,
-- once for the embedded result), so we flag the tooltip after adding a line
-- and clear the flag when the tooltip is reset.
local EC_tooltipHooked = false

-- EC-TRAP: this deliberately MIRRORS EC_IsSellable (EbonClearance_Events.lua)
-- rather than calling it - it needs the WHY (per-outcome labels), not a
-- yes/no. Do NOT refactor the two into one shared function. See
-- docs/CODE_REVIEW.md item 6.
local function EC_AnnotateTooltip(tooltip)
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB or not tooltip or not tooltip.GetItem then
        return
    end
    -- Honour the addon-enabled toggle and per-character allowlist. If the
    -- addon won't act on the item, don't mislead the user by annotating it.
    if NS.IsAddonEnabledForChar and not NS.IsAddonEnabledForChar() then
        return
    end
    if tooltip.__EC_annotated then
        return
    end
    local _, link = tooltip:GetItem()
    if not link then
        return
    end
    local id = tonumber(link:match("|Hitem:(%d+)"))
    if not id then
        return
    end

    -- Hoisted GetItemInfo: the function used to call it three separate
    -- times (whitelist branch reading sellPrice, qualityRules branch
    -- reading quality/ilvl/equipLoc/sellPrice, affix block reading
    -- quality). All read different subsets of the same cached tuple, so
    -- a single call up here serves every branch below without changing
    -- any per-branch nil-handling. Uncached items still surface as
    -- "Won't Sell (no value)" via the existing sellPrice nil-guards.
    local _, _, itemQuality, itemILvl, _, _, _, _, itemEquipLoc, _, itemSellPrice = GetItemInfo(id)

    -- EC-TRAP: statusLine is the DISPLAYED verdict and may be translated, so
    -- it can no longer be introspected for logic (a frFR client's "Vente" will
    -- not match :find("Will Sell")). statusTag carries the English verdict
    -- token instead - every statusLine assignment sets a matching tag, and the
    -- downstream "is this a Will Sell / affix-rank / tome-known verdict?"
    -- checks read the tag, never the string. Do NOT reintroduce
    -- statusLine:find(...) for control flow.
    local statusLine, statusTag
    if IsInSet(DB.blacklist, id) then
        -- v2.10.0: distinguish "user manually blacklisted this" from "the
        -- auto-protect-equipped path added it". DB.blacklistAuto is stamped
        -- only by the equipment handler / one-shot sync; manual adds don't
        -- touch it. The suffix is concatenated onto the existing label so
        -- the annotation stays a single line. The suffix tells the user
        -- "this is on Keep because you equipped it, not because you hand-
        -- added it" - useful when they expected an item to vendor and want
        -- to know why the rules are leaving it alone. The override is the
        -- existing Alt+Right-Click context menu's "Remove from Blacklist"
        -- row.
        local autoTag = DB.blacklistAuto and DB.blacklistAuto[id]
        if autoTag then
            -- v2.12.0: origin-aware label. The auto-protect path stamps
            -- one of two string tags so the tooltip can tell the user
            -- WHICH rule kept the item. Legacy boolean-true entries from
            -- v2.10.0 / v2.11.0 fall back to the generic label.
            if autoTag == "equipped" then
                statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (equipped)"] .. "|r"
            elseif autoTag == "upgrade" then
                statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (upgrade)"] .. "|r"
            elseif autoTag == "set" then
                -- v2.13.0: items from a saved Blizzard Equipment Manager set.
                -- Most likely an off-set / dual-spec piece sitting in bags
                -- between swaps; the tag promotes to "(equipped)" the next
                -- time the user actually equips it.
                statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (in gear set)"] .. "|r"
            else
                statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (auto)"] .. "|r"
            end
        else
            statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep"] .. "|r"
        end
        statusTag = "keep"
    elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
        statusLine = "|cff66ccff[EC]|r |cffff4444" .. L["Will Delete"] .. "|r"
        statusTag = "willdelete"
    elseif IsInSet(DB.whitelist, id) or (ADB and IsInSet(ADB.whitelist, id)) then
        -- Honesty: EC_IsSellable also requires sellPrice > 0 and not currently
        -- equipped. Without these checks the tooltip used to claim "Will Sell"
        -- on items that the merchant cycle correctly refuses (custom items
        -- with no vendor price, or items the player has equipped). Surface
        -- both reasons in warning-yellow so the user sees them at the point
        -- of decision instead of wondering why the cycle skipped them.
        if IsEquippedItem(id) then
            statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Won't Sell (equipped)"] .. "|r"
            statusTag = "wontsell"
        elseif not (itemSellPrice and itemSellPrice > 0) then
            statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Won't Sell (no value)"] .. "|r"
            statusTag = "wontsell"
        else
            statusLine = "|cff66ccff[EC]|r |cffb6ffb6" .. L["Will Sell"] .. "|r"
            statusTag = "willsell"
        end
    elseif DB.qualityRules then
        local quality, ilvl, equipLoc, sellPrice = itemQuality, itemILvl, itemEquipLoc, itemSellPrice
        -- Grey-quality invariant. EC_IsSellable's "isJunk" branch always
        -- matches a grey item with a positive sell price - independent of
        -- DB.qualityRules, useEquippedILvl, bind filter, or any other
        -- rule setting. Mirror that here so users see why an Item-Level
        -- 47 grey shoulderpad on their level-80 character will vendor.
        -- Reported by an in-game tester via Discord: "I dont see the Will
        -- Sell - Junk".
        if quality == 0 and sellPrice and sellPrice > 0 then
            statusLine = "|cff66ccff[EC]|r |cffb6ffb6" .. L["Will Sell (junk)"] .. "|r"
            statusTag = "willsell"
        elseif quality and quality >= 1 and quality <= 4 and sellPrice and sellPrice > 0 then
            local rule = DB.qualityRules[quality]
            if rule and rule.enabled then
                local rarityName = (quality == 1) and L["White"]
                    or (quality == 2) and L["Green"]
                    or (quality == 3) and L["Blue"]
                    or L["Epic"]
                local hasVisibleILvl = equipLoc and equipLoc ~= "" and ilvl and ilvl > 0
                -- v2.12.0: split on useEquippedILvl mode. Dynamic-cap mode
                -- mirrors EC_compCache.isDowngradeVsEquipped semantics so
                -- the tooltip is honest about what will / won't sell.
                local matchesILvl = false
                local matchedAgainstEquipped = false
                -- v2.44.6: capture the reason isDowngradeVsEquipped gives
                -- back so the "Keep (possible upgrade)" branch below can
                -- distinguish "this item type has no equipment slot we
                -- can compare against" (ammo, bags, tabards, class-
                -- restricted relics) from "real upgrade candidate". Both
                -- previously fell into the "possible upgrade" branch,
                -- mislabelling Doomshot etc.
                local equipReason = nil
                local cap = rule.maxILvl or 0
                if rule.useEquippedILvl then
                    matchedAgainstEquipped = true
                    if hasVisibleILvl then
                        local downgrade, reason = EC_compCache.isDowngradeVsEquipped(id, ilvl, equipLoc)
                        if downgrade then
                            matchesILvl = true
                        end
                        equipReason = reason
                    end
                else
                    matchesILvl = (cap == 0) or (hasVisibleILvl and ilvl <= cap)
                end
                if matchesILvl and EC_compCache.isQuestItem and EC_compCache.isQuestItem(id) then
                    -- v2.13.x: quest-item safety-net honesty. After the
                    -- v2.13.x narrowing, EC_IsSellable returns false when
                    -- a qualityPass auto-rule would catch a quest-class
                    -- item. Reflect that here so the tooltip doesn't
                    -- claim "Will Sell" when the merchant cycle will
                    -- silently skip. The whitelist match path above is
                    -- unaffected (whitelist overrides safety net).
                    statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (quest item)"] .. "|r"
                    statusTag = "keep"
                elseif
                    matchesILvl
                    and EC_compCache.baselineProtectedIDs
                    and EC_compCache.baselineProtectedIDs[id]
                    and not (ADB and ADB.allowedItems and ADB.allowedItems[id])
                then
                    -- Baseline profession-tool safety net (Monrad's report).
                    -- Same honesty as the quest-item case: the auto-rule
                    -- sweep would have caught the tool but EC_IsSellable
                    -- vetoes; the tooltip should say so. Allow Sell
                    -- override unsets this annotation (the item flows to
                    -- the normal sell path).
                    statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (profession tool)"] .. "|r"
                    statusTag = "keep"
                elseif matchesILvl then
                    -- v2.10.0: bind-filter check. EC_IsSellable applies this
                    -- AFTER the iLvl gate; the tooltip annotation has to
                    -- mirror the same chain so users get an accurate read
                    -- of what the rules will do at the next vendor visit.
                    local bindFilter = rule.bindFilter or "any"
                    local bindRejected = false
                    if bindFilter ~= "any" then
                        local bindType = EC_compCache.getBindTypeFromTooltip(tooltip, id)
                        if bindType ~= bindFilter then
                            bindRejected = true
                        end
                    end
                    if bindRejected then
                        local fLabel = (bindFilter == "boe") and L["BoE"] or L["BoP"]
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (%s rule wants %s only)"] .. "|r",
                            rarityName,
                            fLabel
                        )
                        statusTag = "keep"
                    elseif matchedAgainstEquipped then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6" .. L["Will Sell (%s, lower than equipped)"] .. "|r",
                            rarityName
                        )
                        statusTag = "willsell"
                    elseif cap == 0 then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6" .. L["Will Sell (%s)"] .. "|r",
                            rarityName
                        )
                        statusTag = "willsell"
                    else
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6" .. L["Will Sell (%s, iLvl %d, cap %d)"] .. "|r",
                            rarityName,
                            ilvl,
                            cap
                        )
                        statusTag = "willsell"
                    end
                elseif matchedAgainstEquipped then
                    -- Dynamic-cap mode and the item didn't qualify. Routes
                    -- on the reason isDowngradeVsEquipped gave us:
                    --   * "no_slot_mapping" / "not_equippable": item has
                    --     no equipment slot the addon can reason about
                    --     (ammo, bags, tabards, class-restricted relics).
                    --     v2.44.6: distinct "Won't Sell" label so the
                    --     player understands the addon ISN'T actively
                    --     protecting these as upgrades - it's just
                    --     declining to evaluate them. statusTag flips
                    --     from "keep" to "wontsell" to match the
                    --     framing of Won't Sell (equipped) and Won't
                    --     Sell (no value). EC-TRAP: don't reframe this
                    --     as "Keep" - a Doomshot/AMMO test case
                    --     reasonably read "Keep" as "the addon thinks
                    --     I should hold onto this", which is the
                    --     opposite of what's actually happening.
                    --   * "empty_slot": rule short-circuited because at
                    --     least one candidate slot is empty - the looted
                    --     item could fill it (relevant for dual-wielders).
                    --   * "at_or_above": actual iLvl compare happened and
                    --     the looted item met or exceeded the lowest
                    --     populated slot - could be an upgrade for the
                    --     weakest slot in a multi-slot equipLoc, or a
                    --     same-iLvl sidegrade.
                    -- "empty_slot" and "at_or_above" both mean "kept because
                    -- this could be useful"; "possible upgrade" is the
                    -- user-friendly framing for both.
                    if equipReason == "no_slot_mapping" or equipReason == "not_equippable" then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84d" .. L["Won't Sell (%s, no equipment slot)"] .. "|r",
                            rarityName
                        )
                        statusTag = "wontsell"
                    elseif not hasVisibleILvl then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (%s, no item level)"] .. "|r",
                            rarityName
                        )
                        statusTag = "keep"
                    else
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (%s, possible upgrade)"] .. "|r",
                            rarityName
                        )
                        statusTag = "keep"
                    end
                elseif not hasVisibleILvl then
                    -- Fixed-cap mode; non-equippable has no visible iLvl.
                    statusLine = string.format(
                        "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (%s, no item level)"] .. "|r",
                        rarityName
                    )
                    statusTag = "keep"
                else
                    -- Fixed-cap mode; equippable item iLvl above cap.
                    statusLine = string.format(
                        "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (%s, iLvl %d, cap %d)"] .. "|r",
                        rarityName,
                        ilvl,
                        cap
                    )
                    statusTag = "keep"
                end
            end
        end
    end

    -- v2.19.0: PE roguelite affix protection - tooltip honesty pass.
    -- If the if/elseif chain above resolved to a would-sell or would-
    -- delete verdict but DB.protectAffixedRareItems is on AND the item
    -- is Rare/Epic AND has an affix, override the label to make it
    -- clear that the merchant cycle won't actually act on this
    -- specific bag instance.
    -- v2.20.0: liveTooltipHasAffix now requires the rank-suffix
    -- pattern in the title, narrowing the check so standard
    -- ItemRandomSuffix.dbc entries (`of the Bear`, `of the Sorcerer`)
    -- don't get protected as PE roguelite affixes.
    -- v2.23.0: when the exact-dupe gate releases an affixed item back
    -- to the sell / delete chain, the status line shows "Allowed -
    -- affix already known" instead of "Protected - Random affix". The
    -- match is by description text scraped from the item's @affix@
    -- line vs the descriptions on engraving spells in the player's
    -- spellbook (see EC_compCache.refreshKnownAffixes).
    -- v2.27.0: always surface the affix state when the item has one
    -- (not only when the would-vendor chain produced a label). Mirrors
    -- the v2.26.0 chance-on-hit tooltip pass so Epic items with
    -- affixes also show their state.
    if DB.protectAffixedRareItems then
        local quality = itemQuality
        if quality and quality >= 3 then
            local affix = EC_compCache.liveTooltipAffixData(tooltip, id)
            if affix then
                -- v2.32.x lazy catalog refresh. Pick up any newly-
                -- learned ExtractionService affixes BEFORE the
                -- playerHasAffixDescription lookup so a player who
                -- learned an affix at the Anvil and immediately
                -- hovers a new drop sees the correct verdict on the
                -- FIRST hover (no waiting for the BAG_UPDATE debounce
                -- + spell-event debounce + chunked scan to settle).
                -- The dirty-check is a cheap count comparison that
                -- early-returns when nothing changed; when dirty, the
                -- v2.32.x refactor does an incremental synchronous
                -- merge so the live map reflects the new state by
                -- the time playerHasAffixDescription reads it below.
                if EC_compCache.refreshExtractionIfDirty then
                    EC_compCache.refreshExtractionIfDirty()
                end
                -- v2.27.0: backfill the affix-meta flag for itemIDs
                -- already on a list. Pre-v2.27 entries didn't get
                -- stamped at add time; hovering the item now after
                -- /reload fills in the flag so the panel renders the
                -- (affix-gated) tag.
                local onAnyList = IsInSet(DB.whitelist, id)
                    or (ADB and IsInSet(ADB.whitelist, id))
                    or IsInSet(DB.blacklist, id)
                    or IsInSet(DB.deleteList, id)
                if onAnyList and ADB then
                    ADB.affixedListedItems = ADB.affixedListedItems or {}
                    if not ADB.affixedListedItems[id] then
                        ADB.affixedListedItems[id] = true
                        if NS.RefreshAllListPanels then
                            NS.RefreshAllListPanels()
                        end
                    end
                end
                local affixKey = affix.description and EC_compCache.normaliseAffixDesc(affix.description)
                local manualAllow = affixKey and ADB and ADB.allowedAffixes and ADB.allowedAffixes[affixKey]
                -- v2.30.x: compute "does the player know this affix at
                -- this rank" INDEPENDENTLY of affixAllowExactDupes so the
                -- "Protected - Affix known" branch can fire even when the
                -- setting is off. Pre-v2.30 the only way to surface
                -- knowledge was via autoDupe, which silently rolled the
                -- "known" state into a blanket "Random affix" label
                -- whenever the dupe-allow flag was off.
                local playerKnows = affix.description
                    and EC_compCache.playerHasAffixDescription
                    and EC_compCache.playerHasAffixDescription(affix.description)
                    or false
                -- v2.35.1: family + rank fallback. PE's item-side and
                -- spell-side strings sometimes disagree at the same rank
                -- (e.g. an "Overwhelming Force II" item reads
                -- "Increases your damage and healing done by 2%" while
                -- the rank II engraving spell reads "Increases damage
                -- and healing done by 4%"). The description match misses
                -- but the player demonstrably has this rank.
                -- knownAffixFamilyRanks tracks (family, rank) pairs from
                -- spellbook names + ExtractionService records, so the
                -- label can be correct even when description-text fails.
                --
                -- Two label outcomes - "do I need this specific rank?":
                --   * description match OR (family, rank) match
                --     -> "Keep (affix rank known)"
                --   * neither (whether family is unknown OR known at a
                --      different rank) -> "Keep (affix rank needed)"
                --
                -- Collector-focused framing: the user cares whether they
                -- need this exact (family, rank) for their collection,
                -- not whether they own a different rank of the same
                -- family - that distinction was noise. playerHasAffixFamily
                -- stays in Protection.lua as a helper for future use
                -- (/ec sellinfo could surface it for diagnostic detail).
                --
                -- The autoDupe release path stays exact-rank-description
                -- only - explicit user opt-in to "allow dupes" means
                -- exact-rank-description match, not family.
                local playerKnowsRank = (not playerKnows)
                    and affix.name
                    and affix.rank
                    and EC_compCache.playerHasAffixRank
                    and EC_compCache.playerHasAffixRank(affix.name, affix.rank)
                    or false
                -- v2.45.0: family-name fallback for unranked PE affixes.
                -- Same shape as the EC_IsSellable affix-protection gate
                -- + Process Bags affix-guard. When the player has the
                -- spell in their spellbook (so the family is known)
                -- but the item-side description has resolved values
                -- ("by 10 Strength") that don't match the spell-side
                -- templated text ("Strength is increased"), this is
                -- the only signal that catches the "yes I have it".
                local playerKnowsFamily = (not playerKnows)
                    and (not playerKnowsRank)
                    and (not affix.rank)
                    and affix.name
                    and EC_compCache.playerHasAffixFamily
                    and EC_compCache.playerHasAffixFamily(affix.name)
                    or false
                -- v2.37.x diagnostic: log the lookup result so a future
                -- "rank needed" misfire report can be debugged from the
                -- affix-debug dump rather than by guessing. Includes
                -- the raw + normalised family key so apostrophe /
                -- character mismatches between item titles and spell
                -- names are visible. Fires per tooltip hover; gated
                -- on the same ADB.affixDebugEnabled flag.
                if EC_compCache.AffixDebugDump then
                    EC_compCache.AffixDebugDump("tooltip.affix.lookup", {
                        itemID = id,
                        rawName = affix.name,
                        rank = affix.rank,
                        normFamily = EC_compCache.normaliseAffixFamily
                            and EC_compCache.normaliseAffixFamily(affix.name) or nil,
                        rawDescription = affix.description,
                        normDescription = affix.description
                            and EC_compCache.normaliseAffixDesc
                            and EC_compCache.normaliseAffixDesc(affix.description) or nil,
                        playerKnowsDesc = playerKnows,
                        playerKnowsRank = playerKnowsRank,
                    })
                end
                -- v2.35.1: autoDupe widens to release on description match
                -- OR (family, rank) match. Keeps the sell-side and label
                -- semantics in sync: when the tooltip says "rank known"
                -- AND dupe-allow is on, the affix protection releases too
                -- (matches what the user requested when shipping the
                -- family + rank fallback).
                local autoDupe = DB.affixAllowExactDupes and (playerKnows or playerKnowsRank or playerKnowsFamily)
                -- v2.47.0: bind-type split mirror. When "keep BoE dupes" is on,
                -- a BoE owned dupe is NOT released (kept for the auction house),
                -- so the tooltip must not say "Will Sell" for it. Reads the bind
                -- line off the live tooltip (no bag/slot here). Keep in lockstep
                -- with EC_IsSellable's autoDupe / autoDupePass gate.
                if autoDupe
                    and DB.keepBoeAffixDupes
                    and EC_compCache.getBindTypeFromTooltip
                    and EC_compCache.getBindTypeFromTooltip(tooltip, id) ~= "bop"
                then
                    autoDupe = false
                end
                -- v2.44.0: rank-floor opt-out. Mirrors the sell-path
                -- so the tooltip reflects the true outcome when an
                -- affixed item is below the player's chosen rank
                -- floor: the protection releases and the destination
                -- / will-sell label below takes over.
                local rankBelow = DB.affixMinSellRank
                    and DB.affixMinSellRank > 0
                    and affix.rank
                    and affix.rank < DB.affixMinSellRank
                -- v2.44.0: rankBelow IS a positive sell rule (handled
                -- in EC_IsSellable via affixRankPass), not just a
                -- release-only lever like manualAllow / autoDupe. So
                -- when rankBelow is true and no upstream Will Sell
                -- already exists, the tooltip should affirmatively
                -- say "Will Sell (...)", not "Affix released - add
                -- to a list". Branch detection below: rankBelowOnly
                -- means rankBelow released the protection AND neither
                -- manualAllow nor autoDupe did.
                local rankBelowOnly = rankBelow and not manualAllow and not autoDupe
                -- v2.48.1 hasSellPrice gate mirror: if the item has no
                -- vendor value, the sell path can't actually fire (see
                -- EC_IsSellable's affixRankPass / autoDupePass gates).
                -- Don't relabel to "Will Sell" for unsellable items -
                -- the vendor would refuse and the label would lie.
                -- The v2.47.0 autoMarkAffixDupes toggle covers the
                -- deletion flow for owned unsellable-affix dupes as a
                -- separate code path. Reported by Serv against
                -- Sentinel's Blade of Iron Will II.
                local canSell = itemSellPrice and itemSellPrice > 0
                if canSell and (manualAllow or autoDupe or rankBelow) then
                    -- Destination-list label wins. destinationLabel walks
                    -- the explicit-list precedence chain (Keep / Delete /
                    -- Account Sell / Character Sell) and returns the
                    -- appropriate label; Keep List leaves the earlier
                    -- Keep label unchanged. Returns nil when no list
                    -- claims it, in which case the manualAllow / autoDupe
                    -- branch picks its own fallback.
                    local newLine, newTag = destinationLabel(id, statusLine, statusTag)
                    if newLine then
                        statusLine = newLine
                        statusTag = newTag
                    elseif manualAllow then
                        -- Allow Sell is on but no list claims it. An
                        -- existing "Will Sell (...)" verdict from the
                        -- quality-rule sweep already tells the truth;
                        -- otherwise prompt the user to pick a list.
                        if statusTag ~= "willsell" then
                            statusLine = "|cff66ccff[EC]|r |cffffea80"
                                .. L["Override on - add to a list to sell"]
                                .. "|r"
                            statusTag = "override"
                        end
                    elseif rankBelowOnly then
                        -- v2.44.0: the rank-floor slider IS a sell
                        -- rule (affixRankPass in EC_IsSellable). When
                        -- it's the only release path and there's no
                        -- upstream "Will Sell" verdict yet, the
                        -- tooltip should say so plainly. Pre-v2.44.0
                        -- iter shipped this case with the "Affix
                        -- released - add to a list" label, which was
                        -- accurate before but misleading now (the
                        -- slider has already provided the sell
                        -- signal; the player doesn't need to add to a
                        -- list).
                        if statusTag ~= "willsell" then
                            statusLine = "|cff66ccff[EC]|r |cffb6ffb6"
                                .. L["Will Sell (low-rank affix)"]
                                .. "|r"
                            statusTag = "willsell"
                        end
                    else
                        -- autoDupe only, not on any list. v2.35.1: only
                        -- label "Will Sell (you have this affix)" if an
                        -- UPSTREAM "Will Sell" verdict already exists
                        -- (quality-rule match or whitelist). The dupe-
                        -- allow setting only RELEASES the affix
                        -- protection from vetoing - it doesn't ADD a
                        -- sell signal. Without an upstream Will Sell,
                        -- the item won't actually vendor (no rule fires)
                        -- and labelling it "Will Sell" creates a
                        -- tooltip-vs-vendor divergence (reported in-
                        -- game: Epic item, Epic rule disabled, not on
                        -- any list, dupe-allow on, /ec sellinfo says
                        -- "won't sell - no rule matched" but the
                        -- tooltip said "Will Sell (you have this
                        -- affix)"). Honest fallback when no rule fires
                        -- is "rank known" - same as the dupe-allow-off
                        -- case, because the dupe-allow has nothing to
                        -- release.
                        -- v2.44.0: autoDupe is now a positive sell
                        -- signal in EC_IsSellable (hoisted into the
                        -- isJunk / qualityPass / whitelistPass /
                        -- affixRankPass / autoDupePass check) - same
                        -- shape as the slider. So when autoDupe is
                        -- the only release path, the item DOES sell
                        -- on the next vendor visit, regardless of
                        -- the upstream quality-rule verdict. Label
                        -- it unconditionally to match. Pre-v2.44.0
                        -- this branch had to fall back to a release-
                        -- only "Affix released - add to a list to
                        -- sell" label because autoDupe couldn't fire
                        -- the sell by itself; that constraint is
                        -- gone now.
                        statusLine = "|cff66ccff[EC]|r |cffb6ffb6"
                            .. L["Will Sell (you have this affix)"]
                            .. "|r"
                        statusTag = "willsell"
                    end
                elseif (manualAllow or autoDupe or (rankBelow and (playerKnows or playerKnowsRank or playerKnowsFamily))) and not canSell then
                    -- v2.48.1: affix would be released (player wants it
                    -- gone) AND item has no vendor value - the sell
                    -- path can't fire. Two outcomes:
                    -- (1) If Auto-mark unsellable affixes for deletion is
                    --     ON (and deletion is enabled), runAutoMarkAffixDupes
                    --     will add this item to the Delete List on the next
                    --     BAG_UPDATE. Label as WILL DELETE so the tooltip
                    --     matches the actual outcome.
                    -- (2) Otherwise the item sits with no automatic action.
                    --     Show WON'T SELL (no value) instead of the
                    --     misleading Keep (affix rank known) - the player
                    --     explicitly said "sell this affix" via rank floor
                    --     or dupe-allow, so "keep" reads wrong.
                    --
                    -- v2.48.1 refinement (Serv): rankBelow release ALONE
                    -- doesn't route to "unsellable disposal" when the
                    -- player doesn't own the affix at this rank. The floor
                    -- policy is "sell low-rank if I can" - for unsellable
                    -- items the sell path is inert, and keeping the item
                    -- for extraction is more valuable than deleting it
                    -- with no gold gained. Ownership is required for the
                    -- rankBelow branch (autoDupe already requires it;
                    -- manualAllow is explicit user intent, stays exempt).
                    if DB.autoMarkAffixDupes and DB.enableDeletion and DB.protectAffixedRareItems then
                        statusLine = "|cff66ccff[EC]|r |cffff8040"
                            .. L["Will Delete (unsellable affix)"]
                            .. "|r"
                        statusTag = "willdelete"
                    else
                        statusLine = "|cff66ccff[EC]|r |cffffb84d"
                            .. L["Won't Sell (no value)"]
                            .. "|r"
                        statusTag = "wontsell"
                    end
                elseif playerKnows or playerKnowsRank or playerKnowsFamily then
                    -- The player has this exact (family, rank) - either
                    -- via description-text match (the v2.23.0 path) or
                    -- via the v2.35.1 family+rank fallback when PE's
                    -- text disagrees at the same rank, or via the
                    -- v2.45.0 family-name-only fallback for unranked
                    -- PE transferred procs. Dupe-allow off so
                    -- protection still holds.
                    if affix.rank then
                        statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (affix rank known)"] .. "|r"
                    else
                        statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (affix known)"] .. "|r"
                    end
                    statusTag = "affixknown"
                else
                    -- Player doesn't have this specific (family, rank)
                    -- pair in their collection. Could be a completely
                    -- new family OR a different rank of a family they
                    -- already own - the user's collection-side question
                    -- is "do I need this exact rank?" and the answer
                    -- is the same either way: yes.
                    -- v2.45.0: rank=nil case uses the affix-only label.
                    if affix.rank then
                        statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (affix rank needed)"] .. "|r"
                    else
                        statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (affix needed)"] .. "|r"
                    end
                    statusTag = "affixneeded"
                end
            end
        end
    end

    -- v2.20.0: Chance-on-hit protection - tooltip honesty pass.
    -- v2.20.1: narrowed to "Will Sell - <rarity>" verdicts (the
    -- quality-rule sweep labels). Plain "Will Sell" (whitelist match)
    -- and "Will Delete" (Delete List match) stay as-is because they
    -- represent explicit user intent; chance-on-hit protection no
    -- longer overrides those (the user has typically already
    -- extracted the proc and is dumping the base item).
    --
    -- Discriminator: quality-rule labels always have " - " separator
    -- after "Will Sell" (e.g. "Will Sell - Green iLvl 25 (cap 35)").
    -- The plain whitelist label is just "Will Sell" with no separator.
    -- Lua pattern "Will Sell %- " (escaped dash) matches only the
    -- quality-rule variant.
    -- v2.26.0: chance-on-hit state is always surfaced when the item
    -- has the proc, regardless of whether the auto-rule sweep would
    -- fire. Epic items (default quality rule off) still show the
    -- protection state.
    --
    -- Unmarked items always show "Protected - Chance on hit" (the
    -- protection overrides any other status).
    --
    -- Marked items show the actual destination so the user can see
    -- where the item will go: explicit list membership (Account Sell,
    -- Character Sell, Delete) takes the specific label; otherwise
    -- the item will fall through to the quality-rule sweep and the
    -- label is plain "Allowed - Sell". Keep List membership wins
    -- everything else; we don't override the Kept label.
    if DB.protectChanceOnHitItems and EC_compCache.liveTooltipHasChanceOnHit(tooltip, id) then
        -- Explicit user lists override the safety net. The protection
        -- veto in EC_IsSellable only narrows qualityPass; whitelistPass
        -- (explicit Sell List entry) keeps the item sellable. BuildQueue's
        -- delete path also doesn't gate on chance-on-hit (v2.20.1 note).
        -- So if the item is on Sell / Account Sell / Delete / Keep, the
        -- earlier annotation chain produced the correct verdict already;
        -- don't overwrite it.
        local onExplicit = IsInSet(DB.blacklist, id)
            or IsInSet(DB.whitelist, id)
            or (ADB and IsInSet(ADB.whitelist, id))
            or (IsInSet(DB.deleteList, id) and DB.enableDeletion)
        -- v2.37.0: backfill the chance-on-hit-meta flag for itemIDs
        -- already on a list. Mirrors the affixedListedItems backfill
        -- above so pre-v2.37 entries get tagged the moment the player
        -- hovers the item. The list panels render "(Hit-proc)" once
        -- the flag is set.
        if onExplicit and ADB then
            ADB.chanceOnHitListedItems = ADB.chanceOnHitListedItems or {}
            if not ADB.chanceOnHitListedItems[id] then
                ADB.chanceOnHitListedItems[id] = true
                if NS.RefreshAllListPanels then
                    NS.RefreshAllListPanels()
                end
            end
        end
        -- v2.37.0 polish: affix protection wins over chance-on-hit when
        -- both apply. PE rule: a chance-on-hit can't be extracted from
        -- an item that already has an affix (you have to extract the
        -- affix first), and players typically value the affix more.
        -- So leave the "Keep (affix rank known/needed)" label alone
        -- instead of overwriting with "Keep (chance-on-hit proc)". The
        -- sell-side + delete-side decisions in EC_IsSellable and
        -- BuildQueue already check affix first, so this aligns the
        -- tooltip with the existing behaviour.
        local affixKept = (statusTag == "affixknown" or statusTag == "affixneeded")
        if onExplicit then
            -- Explicit list verdict stands; leave statusLine alone.
        elseif affixKept then
            -- Affix protection took the verdict already; leave it.
        elseif ADB and ADB.allowedItems and ADB.allowedItems[id] then
            -- Allow Sell is on. If a quality-rule already produced a
            -- "Will Sell (...)" verdict, leave it alone. Otherwise
            -- prompt the user to pick a list.
            if statusTag == "willsell" then
                -- Existing verdict stands.
            else
                statusLine = "|cff66ccff[EC]|r |cffffea80"
                    .. L["Override on - add to a list to sell"]
                    .. "|r"
                statusTag = "override"
            end
        else
            -- v2.49.0: check whether the player has extracted the proc's
            -- PE spell. If yes AND the experimental toggle is on, the
            -- item WILL sell on the next auto-rule sweep - reflect that
            -- in the label. If yes but toggle off, show "known" to
            -- signal the player COULD auto-sell it by flipping the
            -- toggle. If no, keep the pre-v2.49.0 blanket "Keep" label.
            --
            -- v2.49.0 fix (Serv report, Nightfall): knownProcPass is a
            -- POSITIVE sell signal, not just a veto release. When the
            -- proc is extracted AND the toggle is on, the tooltip should
            -- show "Will Sell (chance-on-hit proc known)" - matching
            -- EC_IsSellable's knownProcPass positive-signal path so the
            -- tooltip and the actual sell decision don't diverge. The
            -- earlier "pendingWillSell required" gate was Interpretation-A
            -- (release only); this gate is Interpretation-B (positive
            -- signal), matching the user's original request and the
            -- affix side's DB.affixAllowExactDupes semantics.
            --
            -- v2.49.0 fix (Serv report, Electrified Dagger): also require
            -- itemSellPrice > 0. Soulbound weapons with no vendor value
            -- CANNOT be sold - EC_IsSellable's knownProcPass path gates
            -- on hasSellPrice for the same reason. Without this gate the
            -- tooltip advertises "Will Sell" while the vendor refuses,
            -- diverging from /ec sellinfo which correctly reports "vendor
            -- won't accept".
            local procKnown = false
            if EC_compCache.playerHasExtractedProc and EC_compCache.liveTooltipChanceProcLine then
                local procLine = EC_compCache.liveTooltipChanceProcLine(tooltip)
                if procLine then
                    procKnown = EC_compCache.playerHasExtractedProc(nil, nil, id, procLine)
                end
            end
            local hasSellPriceHere = itemSellPrice and itemSellPrice > 0
            if procKnown and DB.sellChanceOnHitKnown and hasSellPriceHere then
                statusLine = "|cff66ccff[EC]|r |cffb6ffb6"
                    .. L["Will Sell (chance-on-hit proc known)"]
                    .. "|r"
                statusTag = "willsell"
            elseif procKnown then
                statusLine = "|cff66ccff[EC]|r |cffffb84d"
                    .. L["Keep (chance-on-hit proc known)"]
                    .. "|r"
                statusTag = "keep"
            else
                statusLine = "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (chance-on-hit proc)"] .. "|r"
                statusTag = "keep"
            end
        end
    end

    -- Tome protection annotation. Same precedence shape as chance-on-
    -- hit above: a Keep List entry (blacklist) leaves any earlier
    -- Protected / Auto-Protected label alone; an Allow Sell mark
    -- (ADB.allowedItems) rewrites to the destination list; the
    -- unmarked default is "Protected - Tome (unlearned)" or
    -- "Protected - Tome". The aggressive "all tomes" toggle wins over
    -- "unlearned only" - same precedence as EC_IsSellable.
    -- Sell Known Recipes eligibility for THIS character. A learned
    -- profession recipe of an enabled quality is sellable when the feature
    -- is on. Computed before the tome-protection block so it can carve the
    -- recipe out of that veto: the sell opt-in wins over "keep all tomes"
    -- for learned recipes, while non-recipe tomes and unknown recipes stay
    -- protected. Learn-state is read from this character's live tooltip.
    local recipeSellable = DB.sellKnownRecipes
        and itemSellPrice
        and itemSellPrice > 0
        and not IsEquippedItem(id)
        and itemQuality
        and DB.sellKnownRecipeQualities
        and DB.sellKnownRecipeQualities[itemQuality]
        and EC_compCache.liveTooltipIsTome
        and EC_compCache.tomeKind
        and EC_compCache.liveTooltipPlayerKnowsTome
        and EC_compCache.liveTooltipIsTome(tooltip, id)
        and EC_compCache.tomeKind(id) == "Recipe"
        and EC_compCache.liveTooltipPlayerKnowsTome(tooltip, id)
        and true
        or false

    local tomeProtected = false
    local tomeHave = false
    local tomeKindLabel
    if (DB.protectAllTomes or DB.protectUnlearnedTomes)
        and not recipeSellable
        and EC_compCache.liveTooltipIsTome(tooltip, id)
    then
        -- Label the protection accurately. GetItemInfo's class is
        -- "Recipe" for BOTH profession crafting items (Plans /
        -- Schematic / Pattern / Formula / Recipe / Design / Manual)
        -- AND generic spell-teaching tomes (class spell books, mount
        -- scrolls, PE Tome of Echo). The distinguishing field is the
        -- subtype - profession recipes carry a profession-name
        -- subtype; everything else falls through to "Tome".
        tomeKindLabel = (EC_compCache.tomeKind and EC_compCache.tomeKind(id)) or L["Tome"]
        if DB.protectAllTomes then
            tomeProtected = true
            tomeHave = EC_compCache.liveTooltipPlayerKnowsTome(tooltip, id) and true or false
        elseif DB.protectUnlearnedTomes
            and not EC_compCache.liveTooltipPlayerKnowsTome(tooltip, id)
        then
            tomeProtected = true
            tomeHave = false
        end
    end
    if tomeProtected then
        -- Tome protection HARD-VETOES in EC_IsSellable regardless of
        -- Sell List membership, so the Keep label is the truth. Keep
        -- List membership stays. Allow Sell override flips to the
        -- destination-list label.
        if IsInSet(DB.blacklist, id) then
            -- Keep List wins; leave the earlier Keep label alone.
        elseif ADB and ADB.allowedItems and ADB.allowedItems[id] then
            -- destinationLabel walks the explicit-list precedence chain.
            -- Returns nil when no list claims it; the fallback picks an
            -- existing quality-rule "Will Sell" verdict if there is one,
            -- otherwise prompts the user to pick a list.
            local newLine, newTag = destinationLabel(id, statusLine, statusTag)
            if newLine then
                statusLine = newLine
                statusTag = newTag
            elseif statusTag ~= "willsell" then
                statusLine = "|cff66ccff[EC]|r |cffffea80"
                    .. L["Override on - add to a list to sell"]
                    .. "|r"
                statusTag = "override"
            end
        elseif tomeHave then
            statusLine = string.format(
                "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (%s you have)"] .. "|r",
                tomeKindLabel
            )
            statusTag = "tome_have"
        else
            statusLine = string.format(
                "|cff66ccff[EC]|r |cffffb84d" .. L["Keep (new %s)"] .. "|r",
                tomeKindLabel
            )
            statusTag = "tome_new"
        end
    end

    -- Sell Known Recipes verdict. EC_IsSellable sells a learned recipe via
    -- recipePass independently of the per-rarity quality rules, so the
    -- tooltip must say "Will Sell" even when the quality-rule branch above
    -- stamped a "Keep (...)" label on it (e.g. a recipe has no equip slot
    -- to compare against in compare-to-equipped mode). Override that here -
    -- but never override the real Keep List or Delete List (those win in
    -- the engine too), and don't bother relabelling an existing Will Sell.
    -- EC-TRAP: gate on statusTag (English token), never the localized
    -- statusLine.
    if recipeSellable
        and statusTag ~= "willsell"
        and statusTag ~= "willdelete"
        and not IsInSet(DB.blacklist, id)
        and not (IsInSet(DB.deleteList, id) and DB.enableDeletion)
    then
        statusLine = "|cff66ccff[EC]|r |cffb6ffb6" .. L["Will Sell (known recipe)"] .. "|r"
        statusTag = "willsell"
    end

    if statusLine then
        tooltip:AddLine(statusLine)
    end
    -- v2.37.0 (Borrow B): grey "already known" annotation on tome /
    -- recipe items the current character has already learned.
    -- Surfaces the existing tomeIsKnownCache as a user-visible cue
    -- independent of the protection toggles - players running with
    -- protectUnlearnedTomes off AND protectAllTomes off still see
    -- the cue. Skipped when the EC status line already carries a
    -- "(... you have)" suffix from the tome-protection block above
    -- so the annotation doesn't double up. Per-character via the
    -- cache's character-scoped lifecycle (the tooltip scan runs on
    -- THIS character's spellbook + recipe list).
    if id
        and EC_compCache.liveTooltipIsTome
        and EC_compCache.liveTooltipPlayerKnowsTome
        and EC_compCache.liveTooltipIsTome(tooltip, id)
        and EC_compCache.liveTooltipPlayerKnowsTome(tooltip, id)
        and statusTag ~= "tome_have"
    then
        tooltip:AddLine("|cff888888" .. L["Already known by this character"] .. "|r")
    end
    -- Opt-in item-ID annotation. Surfaces the numeric itemID under the
    -- EC verdict line for users filing bug reports or authoring Keep /
    -- Sell / Delete entries by ID. The id has already been parsed at
    -- the top of this function from the |Hitem:NNNN| link, so this is a
    -- single conditional AddLine - no extra parsing cost.
    if DB.showItemIDOnTooltip then
        tooltip:AddLine(string.format("|cff666666" .. L["Item ID: %d"] .. "|r", id))
    end
    -- Discoverability hint for the v2.3.0 right-click context menu. Shown on
    -- every bag/item-link tooltip so users know the action is available.
    tooltip:AddLine("|cff666666" .. L["Alt+Right-Click for EbonClearance menu"] .. "|r")
    tooltip.__EC_annotated = true
    tooltip:Show()
end

local function EC_ClearTooltipFlag(tooltip)
    if tooltip then
        tooltip.__EC_annotated = nil
    end
end

local function EC_InstallTooltipHookOnce()
    if EC_tooltipHooked then
        return
    end
    EC_tooltipHooked = true
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", EC_AnnotateTooltip)
        GameTooltip:HookScript("OnTooltipCleared", EC_ClearTooltipFlag)
    end
    if ItemRefTooltip and ItemRefTooltip.HookScript then
        ItemRefTooltip:HookScript("OnTooltipSetItem", EC_AnnotateTooltip)
        ItemRefTooltip:HookScript("OnTooltipCleared", EC_ClearTooltipFlag)
    end
end

NS.InstallTooltipHookOnce = EC_InstallTooltipHookOnce
