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
--     via the __index passthrough below. A half-finished translation is never
--     broken - missing entries just show English.
--   * adding a language is purely additive: drop in an
--     EbonClearance_Locale_<code>.lua file that calls NS.RegisterLocale, add a
--     .toc line, done. No code anywhere else changes.
--
-- Locale is read once from GetLocale() at load. Only the active locale's table
-- is copied onto L; the other locale files early-return in RegisterLocale, so
-- shipping every language costs one no-op call each on a non-matching client.
--
-- This file loads SECOND per the .toc (right after Core), so NS.L exists
-- before any other file binds `local L = NS.L` in its main chunk.
--
-- Translators: see docs/TRANSLATING.md. Format placeholders (%s, %d) and color
-- codes (|cffxxxxxx ... |r) must be preserved verbatim in every translation.

local NS = select(2, ...)

-- The active client locale (enUS, frFR, deDE, ...). enUS clients never load a
-- locale table; the passthrough handles them.
local EC_locale = (GetLocale and GetLocale()) or "enUS"

-- The single live lookup table. __index returns the key itself, so any string
-- not overridden by the active locale falls back to its English source.
local EC_L = setmetatable({}, {
    __index = function(_, k)
        return k
    end,
})
NS.L = EC_L

-- Per-locale override registration. Each EbonClearance_Locale_<code>.lua calls
-- this with its full key table; only the active locale's entries are copied.
-- An empty-string value is treated as "not translated yet" and skipped, so the
-- key falls back to English. This is intentional - it lets a template ship
-- every key with blank values for the community to fill in incrementally.
function NS.RegisterLocale(code, tbl)
    if code ~= EC_locale then
        return
    end
    for k, v in pairs(tbl) do
        if type(v) == "string" and v ~= "" then
            EC_L[k] = v
        end
    end
end
