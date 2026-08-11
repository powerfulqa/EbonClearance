-- test_proc_suggester.lua (v2.77.0)
-- Runtime test for the DIAGNOSTIC proc-text affix suggester
-- (EC_compCache.suggestAffixFromProcLine) in EbonClearance_Protection.lua. The
-- suggester powers /ec paircheck: it guesses a weapon's affix from its proc line
-- so pairings can be found without staring at a captureproc dump. It is
-- display-only and must never reach the sell path (that boundary is pinned
-- statically in test_perf_guardrails.lua; this suite proves the matching works).
--
-- Slices the real signature table + word-set helper + suggester out of the
-- source and drives them under stock lua5.1 (and 5.2+), mirroring test_dbproxy.

local fails = 0
local function check(name, cond)
    if cond then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        fails = fails + 1
    end
end

local fh = assert(io.open("EbonClearance_Protection.lua", "rb"))
local src = fh:read("*a")
fh:close()

-- The signature table through the end of suggestAffixFromProcLine is one
-- contiguous block; the "-- v2.49.0: scan a bag slot" comment follows it.
local block = src:match("(local EC_WEAPON_PROC_SIGNATURES = {.-\nend)\n\n%-%- v2%.49%.0: scan a bag slot")
assert(block, "could not slice the proc-suggester block out of Protection.lua")

-- Sandbox: stub EC_compCache with a weaponAffixSpellID that resolves a couple of
-- families (as the live catalog would); the suggester assigns itself onto it.
local EC_compCache = {
    weaponAffixSpellID = function(family)
        if family == "Resurgence" then return 700097 end
        if family == "Execution" then return 700090 end
        return nil
    end,
}
local env = setmetatable({
    EC_compCache = EC_compCache,
    string = string, math = math, pairs = pairs, type = type,
}, { __index = _G })

local loader
if loadstring and setfenv then
    loader = assert(loadstring(block))
    setfenv(loader, env)
else
    loader = assert(load(block, "suggester", "t", env))
end
loader()
local suggest = EC_compCache.suggestAffixFromProcLine
check("suggestAffixFromProcLine is defined", type(suggest) == "function")

-- Destiny's real proc line -> Resurgence. This is the case description-matching
-- could never solve: the proc says "Increases Strength", the affix extraction
-- text is about falling below 40% health.
local fam, sid, conf = suggest("Chance on hit: Increases Strength by 200 for 10 sec.")
check("Destiny proc suggests Resurgence", fam == "Resurgence")
check("Destiny suggestion resolves the Resurgence spell id", sid == 700097)
check("Destiny suggestion has a numeric confidence", type(conf) == "number" and conf > 0)

-- The Needler's proc line -> Execution.
local f2 = suggest("Chance on hit: Wounds the target for 75 damage.")
check("Needler-shaped proc suggests Execution", f2 == "Execution")

-- Unknown / empty / nil -> no suggestion (nil), never a wrong guess forced.
check("unrelated proc text yields no suggestion",
    suggest("Chance on hit: does something entirely unlisted here.") == nil)
check("empty string yields no suggestion", suggest("") == nil)
check("nil yields no suggestion", suggest(nil) == nil)

-- A family whose spell id the catalog can't resolve still returns the family
-- (id nil) - the suggester never hard-fails on a missing catalog.
local f3, s3 = suggest("Chance on hit: Steals life from target enemy.")
check("Vampirism-shaped proc suggests the family even with no resolvable id",
    f3 == "Vampirism" and s3 == nil)

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
