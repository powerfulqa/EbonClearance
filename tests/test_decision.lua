-- test_decision.lua - RUNTIME tests for the pure sell-decision core.
--
-- v2.71.0 (decision-classifier Stage 1). Unlike the static-pattern suites,
-- this loads EbonClearance_Decision.lua under stock lua5.1 and exercises
-- NS.Decision.sell(ctx) with fixture contexts - the addon's first runtime
-- coverage of the sell logic. Fixtures cover every reason token plus the
-- golden regression cases from the two field incidents (the v2.57.2
-- ilvl-ceiling near item-loss; the v2.51.2/v2.59.10 Sell-List-vs-tome
-- drift) and the v2.49.0 knownProcPass-only case.
--
-- Run from the repo root: lua tests/test_decision.lua

local fails = 0
local function check(name, ok, why)
    if ok then
        print("PASS  " .. name)
    else
        fails = fails + 1
        print("FAIL  " .. name)
        if why then
            print("      " .. why)
        end
    end
end

-- Load the decision module in isolation. It only touches NS at load time;
-- the WoW-API upvalues at its head resolve to nil here, which is fine -
-- the pure core never calls them and these tests never call buildCtx.
local chunk = assert(loadfile("EbonClearance_Decision.lua"), "cannot load EbonClearance_Decision.lua (run from repo root)")
local NS = {}
chunk("EbonClearance", NS)
local D = NS.Decision
check("module loads and exposes Decision.sell", D ~= nil and type(D.sell) == "function")

local function thunkFalse()
    return false
end
local function thunkNil()
    return nil
end

-- Sentinel for "override this fixture field to nil" - a literal nil in the
-- overrides table would be invisible to pairs().
local NIL = {}

-- Baseline fixture: a plain grey vendor-trash item with a sell price and
-- every feature toggle off. Overrides layer per-case deltas on top.
local function makeCtx(o)
    local ctx = {
        junkOnly = false,
        itemID = 1000,
        count = 1,
        locked = false,
        link = "item:1000",
        quality = 0,
        ilvl = 10,
        equipLoc = "",
        sellPrice = 10,
        whitelistedChar = false,
        whitelistedAccount = false,
        blacklisted = false,
        equipped = false,
        isQuestItem = false,
        baselineProtected = false,
        allowedItem = false,
        qualityRule = nil,
        affixMinSellRank = 0,
        affixAllowExactDupes = false,
        keepBoeAffixDupes = false,
        keepBoeBelowRankFloor = false,
        sellKnownRecipes = false,
        sellKnownRecipeQuality = false,
        recipeBindFilter = "any",
        sellChanceOnHitKnown = false,
        protectChanceOnHitItems = false,
        protectAffixedRareItems = false,
        protectAllTomes = false,
        protectUnlearnedTomes = false,
        bindType = function()
            return "any"
        end,
        downgradeVsEquipped = thunkFalse,
        affixData = thunkNil,
        saleWithinCeiling = function()
            return true
        end,
        hasChanceOnHit = thunkFalse,
        chanceProcLine = thunkNil,
        hasExtractedProc = thunkFalse,
        isExtractableWeaponSlot = thunkFalse,
        isTome = thunkFalse,
        tomeKind = function()
            return "Tome"
        end,
        knowsTomeSpell = thunkFalse,
        affixDescKnown = thunkFalse,
        affixRankKnown = thunkFalse,
        affixFamilyKnown = thunkFalse,
        manualAffixAllow = thunkFalse,
    }
    for k, v in pairs(o or {}) do
        if v == NIL then
            ctx[k] = nil
        else
            ctx[k] = v
        end
    end
    return ctx
end

local function sellsAs(ctx, wantToken)
    local verdict, token = D.sell(ctx)
    return verdict == "sell" and token == wantToken,
        string.format("got verdict=%s token=%s, wanted sell/%s", tostring(verdict), tostring(token), tostring(wantToken))
end
local function keepsAs(ctx, wantToken)
    local verdict, token = D.sell(ctx)
    return verdict == "keep" and token == wantToken,
        string.format("got verdict=%s token=%s, wanted keep/%s", tostring(verdict), tostring(token), tostring(wantToken))
end
local function isNone(ctx)
    local verdict, token = D.sell(ctx)
    return verdict == "none", string.format("got verdict=%s token=%s, wanted none", tostring(verdict), tostring(token))
end

-- ---- empty / locked -------------------------------------------------------
check("empty slot -> none/empty", select(1, (function()
    local v, t = D.sell({ itemID = nil })
    return v == "none" and t == "empty"
end)()))
check("locked slot -> none/locked", (function()
    local v, t = D.sell(makeCtx({ locked = true }))
    return v == "none" and t == "locked"
end)())

-- ---- grey-always-sold invariant (EC-TRAP) ----------------------------------
check("grey with price sells as junk", sellsAs(makeCtx(), "junk"))
check("grey with no price -> none", isNone(makeCtx({ sellPrice = 0 })))
check("grey sells under junkOnly even with lists disabled by junkOnly",
    sellsAs(makeCtx({ junkOnly = true, whitelistedChar = true }), "junk"))

-- ---- quality rules ---------------------------------------------------------
local greenGear = { quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST" }
check("rarity rule cap 0 sells everything of the rarity",
    sellsAs(makeCtx({ quality = 2, ilvl = 40, equipLoc = "", qualityRule = { enabled = true, maxILvl = 0 } }), "quality"))
check("cap > 0: under-cap equippable sells",
    sellsAs(makeCtx({ quality = greenGear.quality, ilvl = 40, equipLoc = greenGear.equipLoc,
        qualityRule = { enabled = true, maxILvl = 50 } }), "quality"))
check("cap > 0: over-cap equippable does not sell",
    isNone(makeCtx({ quality = 2, ilvl = 60, equipLoc = "INVTYPE_CHEST", qualityRule = { enabled = true, maxILvl = 50 } })))
check("cap > 0: no-equipLoc item (trade good) is protected",
    isNone(makeCtx({ quality = 2, ilvl = 60, equipLoc = "", qualityRule = { enabled = true, maxILvl = 50 } })))
check("useEquippedILvl mode follows the downgrade thunk",
    sellsAs(makeCtx({ quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, useEquippedILvl = true },
        downgradeVsEquipped = function() return true end }), "quality"))
check("bind filter mismatch vetoes the rule match",
    isNone(makeCtx({ quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, maxILvl = 0, bindFilter = "bop" } })))
check("bind filter match keeps the rule match",
    sellsAs(makeCtx({ quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, maxILvl = 0, bindFilter = "bop" },
        bindType = function() return "bop" end }), "quality"))

-- ---- lists + safety nets ---------------------------------------------------
check("character Sell List sells as whitelist_char",
    sellsAs(makeCtx({ quality = 2, whitelistedChar = true }), "whitelist_char"))
check("account Sell List sells as whitelist_account",
    sellsAs(makeCtx({ quality = 2, whitelistedAccount = true }), "whitelist_account"))
check("quest item vetoes the auto-rule sweep",
    isNone(makeCtx({ quality = 2, isQuestItem = true, qualityRule = { enabled = true, maxILvl = 0 } })))
check("quest item on the Sell List still sells (user intent overrides)",
    sellsAs(makeCtx({ quality = 2, isQuestItem = true, whitelistedChar = true }), "whitelist_char"))
check("baseline profession tool vetoes the sweep",
    isNone(makeCtx({ quality = 1, baselineProtected = true, qualityRule = { enabled = true, maxILvl = 0 } })))
check("Allow Sell bypasses the baseline-tool veto",
    sellsAs(makeCtx({ quality = 1, baselineProtected = true, allowedItem = true,
        qualityRule = { enabled = true, maxILvl = 0 } }), "quality"))
check("equipped item keeps even when whitelisted",
    keepsAs(makeCtx({ quality = 2, whitelistedChar = true, equipped = true }), "equipped"))
check("Keep List (blacklist) wins over every sell signal",
    keepsAs(makeCtx({ quality = 2, whitelistedChar = true, blacklisted = true }), "blacklist"))

-- ---- affix sell signals ----------------------------------------------------
local function affixed(o)
    local base = {
        quality = 3,
        ilvl = 100,
        equipLoc = "INVTYPE_CHEST",
        affixData = function()
            return { name = "Iron Will", rank = 2, description = "Increases your Strength" }
        end,
    }
    for k, v in pairs(o or {}) do
        base[k] = v
    end
    return makeCtx(base)
end
check("rank below floor sells as affixrank",
    sellsAs(affixed({ affixMinSellRank = 4 }), "affixrank"))
check("keepBoeBelowRankFloor keeps BoE below-floor items",
    isNone(affixed({ affixMinSellRank = 4, keepBoeBelowRankFloor = true, bindType = function() return "boe" end })))
check("owned dupe sells as autodupe (description match)",
    sellsAs(affixed({ affixAllowExactDupes = true, affixDescKnown = function() return true end }), "autodupe"))
check("keepBoeAffixDupes keeps BoE owned dupes",
    isNone(affixed({ affixAllowExactDupes = true, affixDescKnown = function() return true end,
        keepBoeAffixDupes = true, bindType = function() return "boe" end })))
check("GOLDEN (v2.57.2 near item-loss): the iLvl ceiling vetoes affix sell paths",
    isNone(affixed({ affixMinSellRank = 4, saleWithinCeiling = function() return false end })))

-- ---- affix protection ------------------------------------------------------
check("affix protection keeps a whitelisted affixed Rare (no release)",
    keepsAs(affixed({ whitelistedChar = true, protectAffixedRareItems = true }), "affixProtected"))
check("affix-keyed Allow Sell releases the protection",
    sellsAs(affixed({ whitelistedChar = true, protectAffixedRareItems = true,
        manualAffixAllow = function() return true end }), "whitelist_char"))
check("rank below floor releases the protection",
    sellsAs(affixed({ whitelistedChar = true, protectAffixedRareItems = true, affixMinSellRank = 4 }), "whitelist_char"))

-- ---- tome protection -------------------------------------------------------
local function tomeCtx(o)
    local base = {
        quality = 3,
        ilvl = 50,
        equipLoc = "",
        qualityRule = { enabled = true, maxILvl = 0 },
        isTome = function()
            return true
        end,
    }
    for k, v in pairs(o or {}) do
        base[k] = v
    end
    return makeCtx(base)
end
check("protectAllTomes keeps a rule-matched tome",
    keepsAs(tomeCtx({ protectAllTomes = true }), "tomeProtected"))
check("protectUnlearnedTomes keeps an unlearned tome",
    keepsAs(tomeCtx({ protectUnlearnedTomes = true }), "tomeUnlearned"))
check("protectUnlearnedTomes releases a learned tome",
    sellsAs(tomeCtx({ protectUnlearnedTomes = true, knowsTomeSpell = function() return true end }), "quality"))
check("GOLDEN (v2.51.2/v2.59.10 Mooncloth): Sell List releases the tome veto even with a rule match",
    sellsAs(tomeCtx({ protectAllTomes = true, whitelistedChar = true }), "whitelist_char"))
check("Sell Known Recipes overrides protectAllTomes for a learned recipe",
    sellsAs(tomeCtx({ protectAllTomes = true, sellKnownRecipes = true, sellKnownRecipeQuality = true,
        tomeKind = function() return "Recipe" end, knowsTomeSpell = function() return true end }), "recipe"))
check("recipe bind filter vetoes a mismatched recipe",
    isNone(tomeCtx({ sellKnownRecipes = true, sellKnownRecipeQuality = true, qualityRule = NIL,
        tomeKind = function() return "Recipe" end, knowsTomeSpell = function() return true end,
        recipeBindFilter = "bop" })))

-- ---- chance-on-hit ---------------------------------------------------------
local function procCtx(o)
    local base = {
        quality = 3,
        ilvl = 60,
        equipLoc = "INVTYPE_WEAPON",
        qualityRule = { enabled = true, maxILvl = 0 },
        protectChanceOnHitItems = true,
        hasChanceOnHit = function()
            return true
        end,
        isExtractableWeaponSlot = function()
            return true
        end,
    }
    for k, v in pairs(o or {}) do
        base[k] = v
    end
    return makeCtx(base)
end
check("chance-on-hit protection keeps a rule-matched weapon",
    keepsAs(procCtx(), "chanceonhit"))
check("non-weapon slots fall through to normal rules (v2.60.0 Anvil rule)",
    sellsAs(procCtx({ isExtractableWeaponSlot = thunkFalse }), "quality"))
check("per-item Allow Sell releases the proc protection",
    sellsAs(procCtx({ allowedItem = true }), "quality"))
check("Sell List is exempt from the proc protection",
    sellsAs(procCtx({ qualityRule = NIL, whitelistedChar = true }), "whitelist_char"))
check("GOLDEN (v2.49.0 Nightfall): extracted proc + toggle sells with no other signal",
    sellsAs(procCtx({ qualityRule = NIL, sellChanceOnHitKnown = true,
        chanceProcLine = function() return "Chance on hit: does things" end,
        hasExtractedProc = function() return true end }), "knownproc"))

-- ---- merchant mode (junkOnly) + sell-price gates ----------------------------
-- Runtime companions to the static pins in test_perf_guardrails (Tests
-- 109d / 109e / 110k): every positive signal except isJunk must honour
-- junkOnly (Windrunner Legguards report) and the affix signals must not
-- fire for items the vendor refuses (sellPrice = 0, Sentinel's Blade
-- report).
check("junkOnly: quality rule does not fire at a disallowed merchant",
    isNone(makeCtx({ junkOnly = true, quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, maxILvl = 0 } })))
check("junkOnly: Sell List does not fire at a disallowed merchant",
    isNone(makeCtx({ junkOnly = true, quality = 2, whitelistedChar = true })))
check("junkOnly: affixrank does not fire at a disallowed merchant",
    isNone(affixed({ junkOnly = true, affixMinSellRank = 4 })))
check("junkOnly: autodupe does not fire at a disallowed merchant",
    isNone(affixed({ junkOnly = true, affixAllowExactDupes = true,
        affixDescKnown = function() return true end })))
check("junkOnly: knownproc does not fire at a disallowed merchant",
    isNone(procCtx({ junkOnly = true, qualityRule = NIL, sellChanceOnHitKnown = true,
        chanceProcLine = function() return "Chance on hit: does things" end,
        hasExtractedProc = function() return true end })))
check("sellPrice=0: affixrank does not fire for a vendor-refused item",
    isNone(affixed({ affixMinSellRank = 4, sellPrice = 0 })))
check("sellPrice=0: autodupe does not fire for a vendor-refused item",
    isNone(affixed({ affixAllowExactDupes = true, sellPrice = 0,
        affixDescKnown = function() return true end })))

-- ---- delete eligibility (v2.71.3, classifier Stage 4) -----------------------
-- Decision.deleteEligible(ctx): the Delete-List destruction gate. The
-- v2.50.2 rescue vetoes (Keep List / ACCOUNT Sell List / equipped) are the
-- load-bearing part - auto-mark writes to deleteList without the cross-list
-- conflict guard, so later Keep intent must rescue at destruction time.
check("module exposes Decision.deleteEligible", type(D.deleteEligible) == "function")
local function delAs(ctx, wantEligible, wantToken)
    local eligible, token = D.deleteEligible(ctx)
    return eligible == wantEligible and token == wantToken,
        string.format("got eligible=%s token=%s, wanted %s/%s",
            tostring(eligible), tostring(token), tostring(wantEligible), tostring(wantToken))
end
local function deletable(o)
    o = o or {}
    o.onDeleteList = (o.onDeleteList == nil) and true or o.onDeleteList
    if o.affixDisposable == nil then
        o.affixDisposable = thunkFalse
    end
    return makeCtx(o)
end
check("empty slot -> false/empty", delAs(deletable({ itemID = NIL }), false, "empty"))
check("not on Delete List -> false/notOnList", delAs(deletable({ onDeleteList = false }), false, "notOnList"))
check("listed grey item is eligible", delAs(deletable(), true, "deleteList"))
check("GOLDEN (v2.50.2 shirt-loss): Keep List rescues a listed item",
    delAs(deletable({ blacklisted = true }), false, "keepList"))
check("account Sell List rescues a listed item",
    delAs(deletable({ whitelistedAccount = true }), false, "sellList"))
check("character Sell List does NOT rescue (deliberate asymmetry)",
    delAs(deletable({ whitelistedChar = true }), true, "deleteList"))
check("equipped rescues a listed item",
    delAs(deletable({ equipped = true }), false, "equipped"))
check("locked slot is skipped this tick",
    delAs(deletable({ locked = true }), false, "locked"))
check("protected affix vetoes deletion (Rare+, not disposable)",
    delAs(deletable({ quality = 3, protectAffixedRareItems = true,
        affixData = function() return { name = "Iron Will", rank = 2 } end }), false, "affixProtected"))
check("disposable affix releases the veto",
    delAs(deletable({ quality = 3, protectAffixedRareItems = true,
        affixData = function() return { name = "Iron Will", rank = 2 } end,
        affixDisposable = function() return true end }), true, "deleteList"))
check("affix gate skipped below Rare",
    delAs(deletable({ quality = 2, protectAffixedRareItems = true,
        affixData = function() return { name = "Iron Will", rank = 2 } end }), true, "deleteList"))
check("affix gate skipped when protection is off",
    delAs(deletable({ quality = 3, protectAffixedRareItems = false,
        affixData = function() return { name = "Iron Will", rank = 2 } end }), true, "deleteList"))

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
