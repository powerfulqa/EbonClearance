#!/usr/bin/env lua
-- Affix-source resilience invariants (v2.56.0).
--
-- Run from repo root:    lua tests/test_affix_resilience.lua
--
-- EbonClearance reads the player's learned Project Ebonhold affixes from
-- _G.ExtractionService, with the spellbook walk in refreshKnownAffixes as an
-- independent co-source. To keep that source swappable (one line changes if
-- PE ever renames the global) and the fallback verifiable, every FUNCTIONAL
-- consumer must read the catalog through the single accessor
-- EC_compCache.getExtractionCatalog(), which honours the affix-fallback
-- simulate switch. Diagnostics (/ec procdump, /ec captureproc, /ec bugreport,
-- and the /ec affixfallback status line) intentionally read the raw global so
-- they always report the TRUE live state.
--
-- These are static-pattern checks against the source (the WoW API is not
-- mockable under stock lua5.1, so there are no runtime assertions here) - the
-- same style as tests/test_perf_guardrails.lua.

local function read(path)
    local f, err = io.open(path, "r")
    if not f then
        io.stderr:write("FAIL: cannot open " .. path .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    local s = f:read("*a")
    f:close()
    return s
end

local prot = read("EbonClearance_Protection.lua")
local ev = read("EbonClearance_Events.lua")

local fails = 0
local function check(name, ok, msg)
    if ok then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        if msg then
            print("      " .. msg)
        end
        fails = fails + 1
    end
end

-- 1. The single accessor exists.
check(
    "accessor getExtractionCatalog defined",
    prot:find("function EC_compCache.getExtractionCatalog()", 1, true) ~= nil,
    "Protection.lua must define the single catalog accessor EC_compCache.getExtractionCatalog()."
)

-- 2. The accessor honours the simulate flag (returns nil when set), so the
-- spellbook-only fallback path is exercisable in-game / regression-testable.
check(
    "accessor honours the simulate flag",
    prot:find("EC_compCache.simulateExtractionAbsent = false", 1, true) ~= nil
        and prot:match("getExtractionCatalog%(%).-simulateExtractionAbsent.-return nil") ~= nil,
    "getExtractionCatalog must return nil when EC_compCache.simulateExtractionAbsent is set."
)

-- 3. Functional consumers call the accessor rather than the raw global.
-- Protection: accessor def + refreshKnownAffixes merge + refreshExtractionIfDirty
-- + playerHasExtractedProc + findLearnedAffixForItem (>= 5 mentions).
local protCalls = select(2, prot:gsub("getExtractionCatalog%(", ""))
check(
    "Protection consumers route through the accessor",
    protCalls >= 5,
    "Expected >= 5 getExtractionCatalog mentions in Protection.lua (accessor + 4 consumers); found " .. protCalls
)

-- Events: autolearn snapshot + newly-learned detect + the toast name lookup.
local evCalls = select(2, ev:gsub("getExtractionCatalog%(", ""))
check(
    "Events consumers route through the accessor",
    evCalls >= 2,
    "Expected >= 2 getExtractionCatalog mentions in Events.lua (autolearn snapshot/detect); found " .. evCalls
)

-- 4. In Protection.lua the ONLY non-comment raw read of the global is the
-- accessor itself - proof the functional consumers are all centralised.
local rawProt = 0
for line in prot:gmatch("[^\n]+") do
    local trimmed = line:gsub("^%s+", "")
    if trimmed:sub(1, 2) ~= "--" and line:find("_G%.ExtractionService") then
        rawProt = rawProt + 1
    end
end
check(
    "Protection raw global read is centralised to the accessor",
    rawProt == 1,
    "Exactly one non-comment _G.ExtractionService read expected in Protection.lua (inside the accessor); found " .. rawProt
)

-- 5. The spellbook walk is the primary source: refreshKnownAffixes enumerates
-- the spellbook unconditionally (GetNumSpellTabs) and the ExtractionService
-- merge is an additive `if catalog then` step, so the affix map survives a
-- missing / renamed global.
check(
    "spellbook walk is the primary, unconditional source",
    prot:find("function EC_compCache.refreshKnownAffixes()", 1, true) ~= nil
        and prot:find("GetNumSpellTabs", 1, true) ~= nil
        and prot:match("getExtractionCatalog%(%)%s+if catalog then") ~= nil,
    "refreshKnownAffixes must walk the spellbook unconditionally and treat the ExtractionService merge as an additive 'if catalog then' step."
)

-- 6. The verification slash command exists.
check(
    "/ec affixfallback command present",
    ev:find('cmd == "affixfallback"', 1, true) ~= nil,
    "The /ec affixfallback on|off|status command must exist so the fallback can be toggled and verified."
)

-- 7. (v2.74.0; v2.75.0 SAFETY split) The UI-visibility gate and the FUNCTIONAL
-- gate are separate predicates. peFeaturesActive() is the real, multi-sourced
-- answer (peDetected OR catalog OR known-affix map) and must NOT honour the
-- simulate switch. peFeaturesVisible() is UI-only: it short-circuits on the
-- simulate switch (so the non-PE layout is previewable via /ec affixfallback)
-- and otherwise delegates to peFeaturesActive(). Keeping the simulate check OUT
-- of peFeaturesActive is what stops the preview from disabling real proc
-- protection / widening merchant targeting on a live realm (fresh-audit finding
-- 2026-08-03: that path could sell proc weapons the player believed protected).
-- peDetected() alone is a false negative for a player on the affix realm WITHOUT
-- the PE addon (the spellbook walk is server-side truth), so both predicates OR
-- three signals.
check(
    "peFeaturesActive defined, multi-sourced",
    prot:find("function EC_compCache.peFeaturesActive()", 1, true) ~= nil
        and prot:match("peFeaturesActive%(%).-peDetected%(%)") ~= nil
        and prot:match("peFeaturesActive%(%).-getExtractionCatalog%(%)") ~= nil
        and prot:match("peFeaturesActive%(%).-knownAffixDescriptions") ~= nil,
    "EC_compCache.peFeaturesActive() must exist and OR peDetected() with getExtractionCatalog() and the known-affix map."
)
local activeBody = prot:match("function EC_compCache%.peFeaturesActive%(%)(.-)\nend")
check(
    "peFeaturesActive ignores the simulate switch",
    activeBody ~= nil and not activeBody:find("simulateExtractionAbsent", 1, true),
    "peFeaturesActive() must NOT reference simulateExtractionAbsent - the /ec affixfallback UI preview must never reach the functional PE answer, or it disables real item-safety protection."
)
check(
    "peFeaturesVisible is UI-only: short-circuits on simulate, delegates to Active",
    prot:find("function EC_compCache.peFeaturesVisible()", 1, true) ~= nil
        and prot:match("peFeaturesVisible%(%).-simulateExtractionAbsent.-return false") ~= nil
        and prot:match("peFeaturesVisible%(%).-peFeaturesActive%(%)") ~= nil,
    "EC_compCache.peFeaturesVisible() must short-circuit to false on simulateExtractionAbsent and otherwise return peFeaturesActive()."
)

-- 8. (v2.74.0) Every panel that owns a PE-only widget consults the gate, so a
-- new affix setting can't ship visible-on-every-realm by omission.
local PE_PANELS = {
    "EbonClearance_ProtectionPanel.lua",
    "EbonClearance_KeepDeletePanels.lua",
    "EbonClearance_ItemHighlightingPanel.lua",
    "EbonClearance_GuildPanel.lua",
    "EbonClearance_QuickstartPanel.lua",
    "EbonClearance_MainPanel.lua",
    "EbonClearance_HelpPanel.lua",
    "EbonClearance_MerchantPanel.lua", -- the Goblin/normal/all "Sell at" dropdown
    "EbonClearance_ScavengerPanel.lua", -- the whole companion panel
}
local missingGate = {}
for _, path in ipairs(PE_PANELS) do
    if not read(path):find("peFeaturesVisible", 1, true) then
        missingGate[#missingGate + 1] = path
    end
end
check(
    "every PE-bearing panel consults peFeaturesVisible",
    #missingGate == 0,
    "These panels own PE-only widgets but never gate them: " .. table.concat(missingGate, ", ")
)

-- 9. (v2.74.0) Hiding a setting is not enough when the setting defaults ON
-- and the thing that would switch it off is now invisible. Two toggles are in
-- that position, and each needs a matching runtime gate or the player is left
-- with behaviour they can see but cannot reach:
--   * protectChanceOnHitItems - defaults ON, and off-affix-realm there is no
--     extraction to release a proc weapon, so every one would be wedged.
--   * merchantMode - a stored "goblin" would sell at no vendor at all once
--     the dropdown that set it is gone.
-- v2.75.0: the runtime gates must call peFeaturesActive(), NOT the
-- simulate-honouring peFeaturesVisible(). If they read the visible gate,
-- /ec affixfallback (a UI preview) would disable proc protection and widen
-- merchant targeting on a live realm - the fresh-audit item-loss path.
check(
    "hidden-but-defaulted toggles gate on peFeaturesActive (not the UI preview)",
    read("EbonClearance_Decision.lua"):match("peFeaturesActive.-ctx%.protectChanceOnHitItems") ~= nil
        and ev:match("EC_IsMerchantAllowed = function%(%).-peFeaturesActive") ~= nil,
    "Decision's protectChanceOnHitItems gate and EC_IsMerchantAllowed must call peFeaturesActive(), so the /ec affixfallback preview can't disable proc protection or widen merchant targeting on a live realm."
)

-- 10. (v2.74.0) The two stock looting toggles must NOT live on the companion
-- panel, which goes dark on a realm without the pets. They are plain 3.3.5a
-- looting behaviour and moved to the bag-utility panel; putting them back
-- would silently remove them from every non-companion realm.
check(
    "stock looting toggles are off the companion panel",
    read("EbonClearance_ScavengerPanel.lua"):find("EbonClearanceAutoOpenCB", 1, true) == nil
        and read("EbonClearance_ScavengerPanel.lua"):find("EbonClearanceFastLootCB", 1, true) == nil
        and read("EbonClearance_ProcessBagsPanel.lua"):find("EbonClearanceAutoOpenCB", 1, true) ~= nil
        and read("EbonClearance_ProcessBagsPanel.lua"):find("EbonClearanceFastLootCB", 1, true) ~= nil,
    "Auto-open containers and Fast Loot belong on the Process Bags panel, not the Scavenger panel."
)

-- 11. (v2.74.0) The Help filter must handle whole sections, not just single
-- entries, and must not leave a section header standing over nothing. The
-- companion section is the live case: every one of its entries needs the pets,
-- so the marker carries pe = true and the header goes with them.
check(
    "help filter drops PE sections and never leaves an empty header",
    read("EbonClearance_HelpPanel.lua"):find("e.section and e.pe", 1, true) ~= nil
        and read("EbonClearance_HelpPanel.lua"):match('section = "scavenger".-pe = true') ~= nil
        and read("EbonClearance_HelpPanel.lua"):match("if nxt and not nxt%.section then") ~= nil,
    "EC_buildHelpEntries must honour pe = true on a section marker and drop any section left with no entries under it."
)

-- 12. (v2.74.0) The dead "PE addon not detected" grey-out note is gone. The
-- widget it annotated is hidden outright now, so the string was unreachable;
-- leaving it would be a second, contradictory story about the same state.
check(
    "stale PE-not-detected note removed from the panel",
    read("EbonClearance_ProtectionPanel.lua"):find("Project Ebonhold addon not detected", 1, true) == nil,
    "ProtectionPanel should no longer grey-and-explain the PE-absent case; peFeaturesVisible hides those widgets instead."
)

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
