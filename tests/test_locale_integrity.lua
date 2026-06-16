#!/usr/bin/env lua
-- Integrity tests for the EbonClearance localization layer.
-- Run from repo root:  lua tests/test_locale_integrity.lua
--
-- Two kinds of check:
--   1. Functional: load EbonClearance_Locale.lua for real (stubbing GetLocale)
--      and verify the passthrough + override + empty-skip behaviour.
--   2. Per-translation: load each locale TABLE file, capturing its
--      NS.RegisterLocale call, and validate every NON-EMPTY value. Empty
--      values are legitimately "not translated yet" (they fall back to
--      English) and are skipped. The checks catch the mistakes that would
--      break a client at runtime: a dropped/added format placeholder, an
--      unbalanced color code, an em dash, or a retail-only API token.

local LOCALE_FILES = {
    "EbonClearance_Locale_frFR.lua",
    "EbonClearance_Locale_deDE.lua",
}

local fails = 0
local function check(name, cond, msg)
    if cond then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name .. (msg and ("  (" .. msg .. ")") or ""))
        fails = fails + 1
    end
end

-- ---- helpers --------------------------------------------------------------

-- Count format specs in a string, keyed by the spec text, so we can compare
-- the English key against the translation. Matches a % followed by optional
-- flags/width/precision then a conversion char (including %% for a literal).
local function specCounts(s)
    local c = {}
    for spec in s:gmatch("%%[%-%+ #0-9%.]*[diouxXeEfgGqcsp%%]") do
        c[spec] = (c[spec] or 0) + 1
    end
    return c
end

local function sameSpecs(a, b)
    local ca, cb = specCounts(a), specCounts(b)
    for spec, n in pairs(ca) do
        if (cb[spec] or 0) ~= n then
            return false
        end
    end
    for spec, n in pairs(cb) do
        if (ca[spec] or 0) ~= n then
            return false
        end
    end
    return true
end

-- Color codes: every |cXXXXXXXX must be matched by a |r.
local function colorBalanced(s)
    local _, opens = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    local _, closes = s:gsub("|r", "")
    return opens == closes
end

local function readRaw(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- ---- 1. functional: the core L table ------------------------------------

do
    -- Stub GetLocale so the client locale is frFR, then register tables.
    _G.GetLocale = function()
        return "frFR"
    end
    local NS = {}
    local chunk = assert(loadfile("EbonClearance_Locale.lua"))
    chunk("EbonClearance", NS)

    check("core exposes NS.L", type(NS.L) == "table")
    check("core exposes NS.RegisterLocale", type(NS.RegisterLocale) == "function")
    check("core exposes NS.SetLocaleOverride", type(NS.SetLocaleOverride) == "function")
    check("core exposes NS.GetActiveLocale", type(NS.GetActiveLocale) == "function")
    check("core exposes NS.GetClientLocale", type(NS.GetClientLocale) == "function")

    -- Passthrough: unknown key returns itself (English fallback).
    check("passthrough returns the key", NS.L["Totally untranslated key"] == "Totally untranslated key")

    NS.RegisterLocale("frFR", {
        ["Enable EbonClearance"] = "Activer EbonClearance",
        ["Empty stays English"] = "",
    })
    NS.RegisterLocale("deDE", { ["Enable EbonClearance"] = "EbonClearance aktivieren" })

    -- Active locale follows the client (frFR) by default.
    check("client locale reported", NS.GetClientLocale() == "frFR")
    check("active locale defaults to client", NS.GetActiveLocale() == "frFR")
    check("active-locale value resolves", NS.L["Enable EbonClearance"] == "Activer EbonClearance")
    check("empty value falls back to English", NS.L["Empty stays English"] == "Empty stays English")

    -- Override switches the language live (dynamic resolution).
    NS.SetLocaleOverride("deDE")
    check("override changes active locale", NS.GetActiveLocale() == "deDE")
    check("override value resolves live", NS.L["Enable EbonClearance"] == "EbonClearance aktivieren")
    check("client locale unchanged by override", NS.GetClientLocale() == "frFR")

    -- "auto" / false clears the override, back to the client locale.
    NS.SetLocaleOverride("auto")
    check("auto restores client locale", NS.GetActiveLocale() == "frFR")
    check("auto restores client value", NS.L["Enable EbonClearance"] == "Activer EbonClearance")

    -- Overriding to a locale with no table falls back to English (no error).
    NS.SetLocaleOverride("esES")
    check("unknown-locale override falls back to English", NS.L["Enable EbonClearance"] == "Enable EbonClearance")
    NS.SetLocaleOverride(false)
end

-- ---- 2. per-translation validation --------------------------------------

for _, path in ipairs(LOCALE_FILES) do
    -- Capture the RegisterLocale table without needing the real locale match.
    local captured
    local NS = {
        RegisterLocale = function(_, tbl)
            captured = tbl
        end,
    }
    local chunk = assert(loadfile(path))
    chunk("EbonClearance", NS)
    check(path .. " calls RegisterLocale with a table", type(captured) == "table")

    if type(captured) == "table" then
        for k, v in pairs(captured) do
            local label = path .. ": " .. tostring(k):sub(1, 44)
            -- Values must be strings (empty is allowed = untranslated).
            check(label .. " [type]", type(v) == "string", "value is not a string")
            if type(v) == "string" and v ~= "" then
                check(label .. " [placeholders]", sameSpecs(k, v), "format specs differ from the English key")
                check(label .. " [colorcodes]", colorBalanced(v), "unbalanced |cff..|r color code")
            end
        end
    end

    -- Raw-byte scans on the file itself.
    local raw = readRaw(path)
    check(path .. " [no em dash]", not raw:find("\226\128\148", 1, true), "contains U+2014 em dash")
    -- Code-shaped retail-only tokens that would only appear if someone pasted
    -- live code into a translation value. Kept deliberately narrow: prose like
    -- "Merchant Settings. Each ..." must not trip it, so no bare-word tokens.
    local FORBIDDEN = { "C_Timer", "C_Container(", "C_Item.", "C_AddOns.", "EnumerateFrames(" }
    for _, tok in ipairs(FORBIDDEN) do
        check(path .. " [3.3.5a-safe: no " .. tok .. "]", not raw:find(tok, 1, true), "retail-only API token present")
    end
end

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
end
print("RESULT: all tests passed")
os.exit(0)
