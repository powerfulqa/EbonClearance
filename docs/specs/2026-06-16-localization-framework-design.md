# Localization (i18n) framework - design

**Status:** shipped in v2.43.0.
**Context:** an influx of French and German players to the Project Ebonhold server. EbonClearance shipped English-only with ~500 hardcoded player-facing strings across ~25 files. This adds a library-free localization layer keyed off `GetLocale()` so frFR / deDE clients can render translated text, with automatic English fallback for anything not yet translated.

## Decisions

- **Coverage: everything.** Every player-facing string is wrapped, including the full 86-entry Help / FAQ panel.
- **Translations: community-written.** We ship the framework + the full mechanical wrapping + complete fill-in-the-blank locale template files. French / German players fill in the actual text. We do not author the translations.
- **No external libraries.** No AceLocale / LibStub. Blizzard APIs only, Lua 5.1, 3.3.5a-safe.
- This actions the long-parked L10n stub (docs/CODE_REVIEW.md item 2).

## Mechanism

`EbonClearance_Locale.lua` (loads 2nd, right after Core) defines:

- `NS.L` - a table with an `__index` passthrough that returns the key itself. The English text IS the key, so any unset or empty key renders English.
- `NS.RegisterLocale(code, tbl)` - copies a locale table's non-empty values onto `NS.L`, but only when `code == GetLocale()`. Non-active locale files no-op, so every language ships unconditionally at near-zero cost.

`EbonClearance_Locale_frFR.lua` / `_deDE.lua` (load 3rd / 4th) each call `RegisterLocale` with the full key set, values seeded `""`. They are the community contribution surface: a translator replaces `""` with the translation. An empty value falls back to English, so partial translations are always safe to ship.

Load order matters only in that `Locale.lua` must precede any file that binds `local L = NS.L` at its main chunk (hence position 2). Locale-table files only need to follow `Locale.lua`.

## Wrapping pattern

`local L = NS.L` at the top of each emitting file; wrap at the call site, leaving the helpers dumb:

- Chat: `PrintNicef(L["Sold %d items."], n)` - the whole format string is one key (placeholders reorder freely in translation; never concatenate fragments).
- Widgets: `AddCheckbox(..., L["Enable EbonClearance"], ...)`, `MakeHeader(panel, L["..."], y)`.
- Help entries: `{ q = L["..."], a = L["..."] }`; section `title = L["..."]`. `id`/`panel`/`section` are identifiers, not wrapped.
- StaticPopup `.text = L["..."]`; concatenated `.text` collapsed to one key. Engine button globals (`YES`/`NO`/`OKAY`/...) stay unwrapped (the client localizes them).

## The Tooltip exception (EC_AnnotateTooltip)

The tooltip built its verdict label into `statusLine` AND introspected it (`statusLine:find("Will Sell")`, `("(affix rank")`, `(" you have)")`) for control flow. A localized label would break those English `:find` checks on a frFR / deDE client. Fix: a companion `statusTag` English token is set at every `statusLine` assignment; the introspections read the tag, never the displayed string. `destinationLabel` returns `(line, tag)`. Marked with `EC-TRAP:` so nobody reintroduces `statusLine:find(...)` for logic. Verdict label chrome (`|cff66ccff[EC]|r |cffXXXXXX...|r`) stays in code; only the inner human phrase (with any `%s`/`%d`) is wrapped.

## Tests

`tests/test_locale_integrity.lua` (registered in `tests/run_all.lua`):
- Functional: loads `Locale.lua` (stubbed `GetLocale`) and verifies passthrough + active-locale override + empty-skip + non-active-locale ignore.
- Per non-empty translation: format-placeholder parity with the English key (catches a dropped `%s` -> runtime error), color-code balance, and per-file raw-byte scans for U+2014 and code-shaped retail tokens.

The locale files are added to `test_comment_hygiene.lua`'s source list (comment scanning) and the CI `luac` list, but NOT to `test_perf_guardrails.lua`'s concatenated `src` (its substring presence/absence checks would false-match the English keys in the templates).

## Out of scope

- Authoring FR / DE translations (community-written).
- An in-addon locale override (locale follows `GetLocale()`).
- Locales beyond frFR / deDE (framework is extensible: add `EbonClearance_Locale_xxXX.lua` + a `.toc` line + the keys).

## Adding strings later

New player-facing strings get wrapped in `L["..."]` at the call site like any other. To refresh the locale templates with new keys, re-extract every `L["..."]` literal from the shipped sources (a throwaway scanner was used for the initial generation; the template keys must stay byte-identical to the call sites).
