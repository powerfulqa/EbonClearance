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

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
