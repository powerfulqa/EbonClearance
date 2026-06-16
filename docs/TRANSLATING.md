# Translating EbonClearance

EbonClearance can be translated into any language with no code changes. French (`frFR`) and German (`deDE`) templates ship ready to fill in. Anything you don't translate falls back to English, so a partial translation is always safe.

Thank you for helping. This guide is everything you need.

## How it works

Every player-facing string in the addon is looked up by its English text. A locale file is just a list of those English strings paired with your translation:

```lua
NS.RegisterLocale("frFR", {
    ["Enable EbonClearance"] = "Activer EbonClearance",
    ["Sold %d items for %s."] = "%d objets vendus pour %s.",
    -- ... hundreds more ...
})
```

The addon reads your client's language (`GetLocale()`) at login and uses the matching file. On an English client nothing changes.

## How to contribute

1. Open the file for your language:
   - French: `EbonClearance_Locale_frFR.lua`
   - German: `EbonClearance_Locale_deDE.lua`
   - A new language: copy `EbonClearance_Locale_frFR.lua` to `EbonClearance_Locale_<code>.lua`, change the `RegisterLocale("frFR", ...)` code to your locale (e.g. `"esES"`, `"ruRU"`), add the filename to `EbonClearance.toc` right after the other locale lines, and translate.
2. For each line, replace the empty `""` with your translation:
   ```lua
   ["Keep List"] = "",            -- before
   ["Keep List"] = "Liste Garder", -- after
   ```
3. Leave anything you are unsure about as `""`. It will show in English. You do not have to translate everything at once.
4. Run the check (see below) and open a pull request, or send the file to the addon author.

## Rules (these keep the addon from breaking)

- **Do not change the keys.** The left-hand string (in `[" ... "]`) is the lookup key. Only edit the right-hand value.
- **Keep every placeholder.** `%s`, `%d`, `%.1f` and the like are filled in at runtime (item names, counts, gold). Your translation must contain the **same placeholders, same count, same type**. You may move them to wherever they read naturally in your language; you may not add or drop one.
  - `["Sold %d items for %s."] = "%d objets vendus pour %s."` is fine.
  - Dropping the `%s` would crash that message. The test below catches this.
  - Note: you cannot renumber placeholders (no `%1$s`); they fill left to right in the order the addon passes them. Reword around them in that order.
- **Keep color codes exactly.** Sequences like `|cffb6ffb6` ... `|r` are color markup, not words. Copy them verbatim, keep them balanced (every `|cff......` needs its `|r`). Translate only the words between them.
- **No em dashes.** Use a plain hyphen with spaces ( - ), a comma, or a period. (This is a project-wide rule.)
- **Watch length.** German especially runs longer than English. If a translated label looks cut off in-game, shorten the wording. Most panels reflow, but fixed-width checkboxes and buttons can clip.

## Checking your work

From the repository root:

```
lua tests/test_locale_integrity.lua
```

It validates every non-empty translation: placeholder parity with the English key, balanced color codes, no em dashes. Fix any `FAIL` line before submitting. Empty (`""`) entries are skipped, so an unfinished file still passes.

## What is not translated

- Button text like Yes / No / Okay / Cancel - the game already localizes those.
- Item, spell, and zone names - the game supplies those in the player's language.
- Slash commands themselves (`/ec`, `status`, ...) - only their descriptions are translatable.
