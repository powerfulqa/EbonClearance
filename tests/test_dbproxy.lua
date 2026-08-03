-- test_dbproxy.lua (v2.75.0, fresh-audit debt item)
-- Behavioural round-trip test for the three-tier DB proxy in
-- EbonClearance_Events.lua: top-level (account) / per-character / settings-
-- profile routing. Before this, the most load-bearing data structure in the
-- addon was covered only by regex checks against its own source. This slices
-- the REAL EC_DBBuildProxy + PER_CHAR_FIELDS out of the file and drives them
-- against a synthetic saved-variables table under stock lua5.1.

local fails = 0
local function check(name, cond)
    if cond then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        fails = fails + 1
    end
end

local fh = assert(io.open("EbonClearance_Events.lua", "rb"))
local src = fh:read("*a")
fh:close()

-- Slice the two definitions. PER_CHAR_FIELDS is a flat table (no nested "\n}"),
-- so the first "\n}" closes it. EC_DBBuildProxy ends at the "end" immediately
-- before "local DB" (a unique anchor), which skips its inner ends.
local pcf = src:match("(local PER_CHAR_FIELDS = {.-\n})")
local proxy = src:match("(local function EC_DBBuildProxy%(charNamespace%).-\nend)\n\nlocal DB")
assert(pcf, "could not slice PER_CHAR_FIELDS out of Events.lua")
assert(proxy, "could not slice EC_DBBuildProxy out of Events.lua")

-- Synthetic saved-variables. `enabled` differs between the per-char namespace
-- and the frozen top-level so per-character routing is provable. The Default
-- profile HAS fastMode but is MISSING vendorInterval (a field added after it
-- was created) to exercise the #5a legacy fallback.
local EbonClearanceDB = {
    fastMode = "LEGACY_FAST", -- SPF field, frozen top-level value
    vendorInterval = 0.15, -- SPF field, frozen top-level value
    someAccountField = "ACCOUNT", -- a plain account-wide (top-level) field
    enabled = true, -- frozen legacy master-enable (top-level)
    settingsProfiles = {
        Default = { fastMode = "DEFAULT_FAST" }, -- has fastMode, lacks vendorInterval
    },
}
local EC_compCache = { settingsProfileFields = { fastMode = true, vendorInterval = true } }

local env = setmetatable({
    EbonClearanceDB = EbonClearanceDB,
    EC_compCache = EC_compCache,
    rawget = rawget,
    rawset = rawset,
    setmetatable = setmetatable,
    pairs = pairs,
    type = type,
    next = next,
}, { __index = _G })

-- Load the sliced chunk with `env` as its global environment. Works under both
-- Lua 5.1 (loadstring + setfenv) and 5.2+ (load with an _ENV arg), since the
-- addon's CI runs 5.1 while local tooling is newer.
local chunk = pcf .. "\n" .. proxy .. "\nreturn EC_DBBuildProxy"
local loader
if loadstring and setfenv then
    loader = assert(loadstring(chunk))
    setfenv(loader, env)
else
    loader = assert(load(chunk, "dbproxy", "t", env))
end
local buildProxy = loader()

-- charNamespace: a per-char field, a per-char `enabled` that DIFFERS from the
-- frozen top-level, and the active-profile pointer.
local charNS = { blacklist = { [123] = true }, enabled = false, activeSettingsProfile = "Default" }
local DB = buildProxy(charNS)

-- 1. PER_CHAR_FIELDS route to the character namespace.
check("per-char read routes to the char namespace", DB.blacklist == charNS.blacklist)
DB.blacklist = { [999] = true }
check("per-char write routes to the char namespace", charNS.blacklist[999] == true)

-- 2. `enabled` is per-character (v2.75.0): reads the char value even when the
-- frozen top-level says otherwise, and writes land on the char namespace.
check("enabled reads the per-character value (not the account value)",
    DB.enabled == false and EbonClearanceDB.enabled == true)
DB.enabled = true
check("enabled write routes to the char namespace, leaving the account value frozen",
    charNS.enabled == true and EbonClearanceDB.enabled == true)

-- 3. Settings-profile fields route to the active profile.
check("SPF read routes to the active profile", DB.fastMode == "DEFAULT_FAST")
DB.fastMode = "NEW_FAST"
check("SPF write routes to the active profile, not the frozen top-level",
    EbonClearanceDB.settingsProfiles.Default.fastMode == "NEW_FAST"
        and EbonClearanceDB.fastMode == "LEGACY_FAST")

-- 4. #5a: an SPF field the active profile lacks falls back to the frozen
-- top-level legacy value instead of returning nil (the future-field trap).
check("SPF field missing on the profile falls back to the frozen legacy value (#5a)",
    DB.vendorInterval == 0.15)

-- 5. Plain account-wide fields route to the top-level table.
check("account field reads from the top-level table", DB.someAccountField == "ACCOUNT")
DB.someAccountField = "CHANGED"
check("account field write routes to the top-level table", EbonClearanceDB.someAccountField == "CHANGED")

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
