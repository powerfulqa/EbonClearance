-- EbonClearance_Locale - the localization layer.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Hand-rolled i18n, no external library. Every player-facing string in the
-- addon is wrapped at its call site with the English text as the lookup key,
-- so:
--
--   * an untranslated (or empty) key renders the English text automatically,
--     via the __index resolver below. A half-finished translation is never
--     broken - missing entries just show English.
--   * adding a language is purely additive: drop in an
--     EbonClearance_Locale_<code>.lua file that calls NS.RegisterLocale, add a
--     .toc line, done. No code anywhere else changes.
--
-- Resolution is DYNAMIC: NS.L has no stored values; every L[key] access reads
-- the currently-active locale's table through __index. This is what lets the
-- in-game language override (/ec locale, DB.localeOverride) switch the language
-- live - chat, panels rebuilt on show, and tooltips all pick up the new locale
-- on the next access. The active locale is `override or clientLocale`:
--   * clientLocale = GetLocale() (frFR/deDE German/French clients, etc.).
--   * override = a player-chosen code (DB.localeOverride), applied at EnsureDB.
-- Caveat: a few strings baked into module-level tables at FILE LOAD (e.g. some
-- dropdown / rarity labels) capture their value once, before the saved override
-- is read, so they render in the client locale until the next /reload. The
-- client-locale path itself is unaffected (it is known at load).
--
-- This file loads SECOND per the .toc (right after Core), so NS.L exists
-- before any other file binds `local L = NS.L` in its main chunk.
--
-- Translators: see docs/TRANSLATING.md. Format placeholders (%s, %d) and color
-- codes (|cffxxxxxx ... |r) must be preserved verbatim in every translation.

local NS = select(2, ...)

-- The client's own locale, fixed at load (enUS, enGB, frFR, deDE, ...).
local EC_clientLocale = (GetLocale and GetLocale()) or "enUS"

-- Player override (DB.localeOverride). nil = follow the client locale.
local EC_override

-- Every registered locale's table, keyed by code. enUS is never registered
-- (the key-is-English passthrough covers it).
local EC_localeTables = {}
NS.localeTables = EC_localeTables

-- The active locale code: the override if one is set, else the client locale.
local function activeCode()
    return EC_override or EC_clientLocale
end

-- The single lookup table. It stores NOTHING, so every access goes through
-- __index, which resolves against whichever locale is active right now. A key
-- with no (or an empty) translation falls back to its English self.
local EC_L = setmetatable({}, {
    __index = function(_, k)
        local t = EC_localeTables[activeCode()]
        if t then
            local v = t[k]
            if type(v) == "string" and v ~= "" then
                return v
            end
        end
        return k
    end,
})
NS.L = EC_L

-- Per-locale registration. Each EbonClearance_Locale_<code>.lua calls this with
-- its full key table; ALL locales are stored (resolution picks the active one
-- dynamically). Empty-string values stay as "not translated yet" and fall back
-- to English at lookup time - this lets a template ship every key blank for the
-- community to fill in incrementally.
function NS.RegisterLocale(code, tbl)
    EC_localeTables[code] = tbl
end

-- Force a language regardless of the client locale. Pass a locale code
-- ("frFR" / "deDE" / ...) to override, or nil / false / "" / "auto" to follow
-- the client. Takes effect immediately for anything looked up afterwards;
-- strings captured at file load need a /reload to refresh (see the caveat
-- above).
function NS.SetLocaleOverride(code)
    if code == nil or code == false or code == "" or code == "auto" then
        EC_override = nil
    else
        EC_override = code
    end
end

-- The locale that is actually in effect right now (override or client).
function NS.GetActiveLocale()
    return activeCode()
end

-- The client's own locale, ignoring any override.
function NS.GetClientLocale()
    return EC_clientLocale
end

-- Sorted list of locale codes that ship a translation table (for /ec locale).
function NS.GetRegisteredLocales()
    local out = {}
    for code in pairs(EC_localeTables) do
        out[#out + 1] = code
    end
    table.sort(out)
    return out
end
