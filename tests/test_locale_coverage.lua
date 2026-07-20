#!/usr/bin/env lua
-- Coverage tests for the EbonClearance localization layer.
-- Run from repo root:  lua tests/test_locale_coverage.lua   (CI uses lua5.1)
--
-- WHY THIS EXISTS: a player-facing string is looked up in code as L["English"].
-- If that key never gets a matching entry in BOTH locale template files, it can
-- never be translated - it silently falls back to English no matter the client
-- language, and a translator never sees it. This test makes that a build
-- failure instead of a thing someone notices in-game months later. It is the
-- systematic backstop for the per-feature "is the new key in the templates?"
-- assertions (e.g. test_perf_guardrails Tests 96c / 99e).
--
-- Three invariants:
--   1. Parity   - frFR and deDE register the SAME set of keys (adding a key to
--      one file but forgetting the other is a bug).
--   2. Forward FR - every literal L["..."] key used in code exists in frFR.
--   3. Forward DE - every literal L["..."] key used in code exists in deDE.
--
-- KNOWN LIMITATION: a handful of L[var] lookups build the key dynamically
-- (e.g. L[q .. "_title"]). Those can't be resolved statically and are skipped
-- here; parity still keeps fr/de in lockstep for them, and they are added to a
-- table + both files by hand when the feature lands.

local fails = 0
local function check(name, cond, msg)
    if cond then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name .. (msg and ("  (" .. msg .. ")") or ""))
        fails = fails + 1
    end
end

-- ---- source file list (from the .toc, the real load list) -----------------

local function readAll(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local s = fh:read("*a")
    fh:close()
    return s
end

local function sourceFiles()
    local toc = assert(readAll("EbonClearance.toc"), "EbonClearance.toc not found (run from repo root)")
    local list = {}
    for line in (toc .. "\n"):gmatch("(.-)\r?\n") do
        local f = line:match("^(EbonClearance_[%w_]+%.lua)%s*$")
        if f and not f:match("^EbonClearance_Locale") then
            list[#list + 1] = f
        end
    end
    return list
end

-- ---- literal L[...] key extraction (escape-aware) --------------------------

-- Scan for `L[` where L is not part of a longer identifier (so NS.L[, (L[,
-- space-L[ match, but someTableL[ does not), then decode the following Lua
-- string literal via load() so escapes/quotes/brackets resolve exactly.
local function extractKeys(src, set)
    local i, n = 1, #src
    while true do
        local s, e = src:find("L%[", i)
        if not s then
            break
        end
        local prev = s > 1 and src:sub(s - 1, s - 1) or " "
        if prev:match("[%w_]") then
            i = e + 1
        else
            local j = e + 1
            while src:sub(j, j):match("%s") do
                j = j + 1
            end
            local q = src:sub(j, j)
            if q == '"' or q == "'" then
                local k = j + 1
                while k <= n do
                    local c = src:sub(k, k)
                    if c == "\\" then
                        k = k + 2
                    elseif c == q then
                        break
                    else
                        k = k + 1
                    end
                end
                local literal = src:sub(j, k)
                local ok, val = pcall(function()
                    return load("return " .. literal)()
                end)
                if ok and type(val) == "string" then
                    set[val] = true
                end
                i = k + 1
            else
                i = e + 1
            end
        end
    end
end

local codeKeys = {}
for _, f in ipairs(sourceFiles()) do
    local src = readAll(f)
    if src then
        extractKeys(src, codeKeys)
    end
end

-- ---- load the two locale tables -------------------------------------------

local function loadLocale(path)
    local NS = {}
    NS.RegisterLocale = function(_, t)
        NS._t = t
    end
    local chunk = assert(loadfile(path))
    chunk(nil, NS) -- file does: local NS = select(2, ...)
    return NS._t
end
local fr = loadLocale("EbonClearance_Locale_frFR.lua")
local de = loadLocale("EbonClearance_Locale_deDE.lua")

-- ---- helpers ---------------------------------------------------------------

local function keyList(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function sample(list, limit)
    local out = {}
    table.sort(list)
    for idx = 1, math.min(#list, limit or 12) do
        out[#out + 1] = list[idx]
    end
    return table.concat(out, " | ")
end

-- ---- invariant 1: parity (fr key set == de key set) -----------------------

local onlyFr, onlyDe = {}, {}
for k in pairs(fr) do
    if de[k] == nil then
        onlyFr[#onlyFr + 1] = k
    end
end
for k in pairs(de) do
    if fr[k] == nil then
        onlyDe[#onlyDe + 1] = k
    end
end
check(
    "parity: frFR and deDE register the same keys",
    #onlyFr == 0 and #onlyDe == 0,
    (#onlyFr > 0 and ("in fr only: " .. sample(onlyFr)) or "")
        .. (#onlyDe > 0 and ("  in de only: " .. sample(onlyDe)) or "")
)

-- ---- invariants 2 & 3: every code key exists in each template -------------

local missFr, missDe = {}, {}
for k in pairs(codeKeys) do
    if fr[k] == nil then
        missFr[#missFr + 1] = k
    end
    if de[k] == nil then
        missDe[#missDe + 1] = k
    end
end
check(
    "forward frFR: every code L[] key has a frFR entry",
    #missFr == 0,
    #missFr .. " missing, e.g.: " .. sample(missFr)
)
check(
    "forward deDE: every code L[] key has a deDE entry",
    #missDe == 0,
    #missDe .. " missing, e.g.: " .. sample(missDe)
)

print(
    string.format(
        "-- code L[] literal keys: %d   frFR: %d   deDE: %d",
        keyList(codeKeys),
        keyList(fr),
        keyList(de)
    )
)

if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    print("RESULT: " .. fails .. " test(s) failed")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
