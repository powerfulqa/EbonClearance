# Spec: Help / FAQ Interface Options panel

**Date**: 2026-05-26
**Status**: Approved (brainstorming complete; awaiting implementation plan or direct implementation)
**Target release**: v2.36.0 (new feature; minor bump)
**Touched files**: new `EbonClearance_HelpPanel.lua`, `.toc`, `EbonClearance.toc`, `EbonClearance_Events.lua` (slash-command output), `tests/test_perf_guardrails.lua`, `.github/workflows/release.yml` (zip packaging glob), `tests/test_layout_reactivity.lua` (SOURCE_PATHS), `tests/test_no_addon_references.lua` (if it has its own path list), `README.md` (one-line mention).

## Goal

Add a **canonical in-game reference + FAQ** as a new Interface Options panel under EbonClearance. Organised into three sections:

1. **Troubleshooting** - common confusion cases with one-click jumps to the relevant settings panel.
2. **Sell decision gates** - one entry per predicate in the EC_IsSellable / BuildQueue chain. Explains what each `/ec sellinfo` trace step means and when it fires.
3. **Tooltip label meanings** - one entry per `Keep (...) / Will Sell (...) / Won't Sell (...) / Will Delete / Override on ...` label. Tells the user what they're seeing.

Closes the discoverability gap for users who hit common confusions AND the reference gap for users who want to understand the addon's decision model without reading `docs/ADDON_GUIDE.md` or `/ec bugreport`. Total expected entry count: ~40 (10 troubleshooting + ~15 gates + ~17 labels).

## Surface

- New `CreateFrame("Frame", "EbonClearanceOptionsHelp", InterfaceOptionsFramePanelContainer)` panel.
- `panel.name = "Help"`, `panel.parent = "EbonClearance"`.
- Registered **last** in the Interface Options sidebar via `InterfaceOptions_AddCategory` at the end of the .toc load order (so the sidebar reads: Main -> Merchant -> Protection -> Scavenger -> Item Highlighting -> Sell List -> Account Sell List -> Keep List -> Delete List -> Process Bags -> Profiles -> Import/Export -> **Help**).
- Scroll-wrapped via `NS.EC_WrapPanelInScrollFrame` (consistent with the other text-heavy panels like Main and Scavenger).
- `OnShow` wrapped in `EC_compCache.initPanel(self, refresh, build, wrapScroll=true)` for the standard idempotency pattern.

### Visual chrome

The scroll content area is wrapped in the same dark tooltip-style backdrop frame the v2.32.x list panels (Sell / Account Sell / Keep / Delete / Profiles / Process Bags) use around their scroll regions. Pattern:

- `Interface\\Tooltips\\UI-Tooltip-Background` tiled fill at low alpha
- `Interface\\Buttons\\WHITE8x8` 1px edge with mid-grey border colour
- Insets: 6 px on three sides, 28 px on the right (matches the v2.29.0 Import/Export numbers exactly so the scrollbar gutter visually aligns with the chrome's right edge)
- Backdrop colour: `(0, 0, 0, 0.6)`; edge colour: `(0.2, 0.2, 0.2, 1)`

Same `applyBackdrop` helper convention used in the ElvUI-bag-button code (`EC_compCache.buildElvUIBagButtons`) and the existing list-panel implementations. Keeps the Help panel visually consistent with the rest of the addon.

### Collapsible sections

Each of the three sections (Troubleshooting, Gates, Labels) has a clickable header that toggles all entries in that section between expanded and collapsed. Pattern borrowed from the Process Bags panel's collapsible mode-groups:

- Header is a `Button` (UIPanelButtonTemplate or custom) with the section title + a `[+] / [-]` glyph indicating state.
- Click toggles the section.
- Collapse state is persisted in a new per-character DB field `helpSectionsCollapsed = { troubleshooting = bool, gates = bool, labels = bool }`. Added to `PER_CHAR_FIELDS` so the v2.34.0 partition migrates it correctly (matches the `processCollapsedModes` precedent which is also per-character).
- **Initial defaults**: `troubleshooting = false` (expanded), `gates = true` (collapsed), `labels = true` (collapsed). A first-time visitor sees the action-oriented troubleshooting entries; the reference sections are hidden until clicked. Avoids the "wall of text on first open" UX problem.
- When a section is collapsed, its entries are `frame:Hide()` and the next visible widget below anchors to the section header's BOTTOMLEFT directly (not the hidden entries' BOTTOMLEFT). The scroll content's `FitScrollContent` re-runs after each toggle so the scrollbar tracks the visible-content height.

Collapse-state changes don't require a `/reload` - the toggle handler updates DB, re-anchors the visible widgets, and calls `FitScrollContent`.

## Content data structure

All entries live in a file-scope `local EC_HELP_ENTRIES = { ... }` table at the top of `EbonClearance_HelpPanel.lua`. The table is a flat ordered list of mixed entry types:

```lua
local EC_HELP_ENTRIES = {
    { section = "troubleshooting", title = "Troubleshooting" },
    { q = "Why isn't this item selling?",
      a = "Alt+Shift+Right-Click the item ...",
      panel = "EbonClearanceOptionsProtection" },
    -- ... more troubleshooting entries ...

    { section = "gates", title = "How sell decisions work" },
    { q = "What's the order of checks?",
      a = "Each bag item runs through these gates in order: ...",
      panel = nil },
    -- ... more gate-reference entries ...

    { section = "labels", title = "Tooltip label meanings" },
    { q = "Keep (equipped)",
      a = "Auto-added because you currently have this item equipped...",
      panel = "EbonClearanceOptionsProtection" },
    -- ... more label-reference entries ...
}
```

### Entry types

**Section marker** (appears at the start of each group):

- **`section`** (string, required) - stable internal key (`"troubleshooting"`, `"gates"`, `"labels"`). Used as the DB-side collapse-state key.
- **`title`** (string, required) - display label (`"Troubleshooting"`, `"How sell decisions work"`, etc.). Rendered as a clickable section header with collapse-state indicator.

**Content entry**:

- **`q`** (string, required) - the question / label / topic. Rendered as a bold yellow heading via `|cffffff00` colour escape and `GameFontNormal`.
- **`a`** (string, required) - the answer / explanation. Multi-line allowed (the FontString is `SetWordWrap(true)` and width-tracked via `EC_compCache.setPanelWidth`). Rendered via `GameFontHighlight`.
- **`panel`** (string, optional) - the target Interface Options panel's frame name. When present, a `[ Open <Panel Display Name> -> ]` button is rendered at the bottom-right of the entry. When nil, no button.

The render loop walks the table in order; section markers set the current group context (and check the collapse-state) so subsequent content entries either render (if expanded) or stay hidden (if collapsed).

Entries are append-only: adding a new entry is a single block addition. Editing an existing entry is a one-line change. The `q` text is the identifier; no string keys are user-facing.

## Seed entries for v1

Ten troubleshooting entries focused on the most common confusion cases. Wording follows the project's CLAUDE.md "player-facing text stays brief / no jargon" rule.

1. **"Why isn't this item selling?"**
   - A: Alt+Shift+Right-Click the item or type `/ec sellinfo` to print a step-by-step trace of every protection rule. Most common cause is a protection toggle - open the panel below and review.
   - panel: `EbonClearanceOptionsProtection`

2. **"The addon keeps adding my equipped gear to the Keep List."**
   - A: "Keep gear you're wearing" is on by default. Open the panel below and untick it to stop auto-Keep on every equip event.
   - panel: `EbonClearanceOptionsProtection`

3. **"Items keep appearing on Keep List as 'Keep (upgrade)' that I want to vendor."**
   - A: "Keep looted upgrades" auto-adds items whose ilvl is above your currently-equipped piece. Stale entries auto-clean on every BAG_UPDATE since v2.33.1; you can also run `/ec clean upgrades apply` manually. To stop the auto-add entirely, untick the toggle in the panel below.
   - panel: `EbonClearanceOptionsProtection`

4. **"What does 'Keep (affix rank known)' or 'Keep (affix rank needed)' mean on a tooltip?"**
   - A: Project Ebonhold affix items are protected from auto-vendoring. "Rank known" means you've already extracted this exact rank; "Rank needed" means you don't have it yet (whether the family is new or you only have a different rank). The protection toggles are in the panel below; Alt+Right-Click an affixed item for a per-affix `Allow Sell` override.
   - panel: `EbonClearanceOptionsProtection`

5. **"Why are my Sell / Keep / Delete lists different on each character?"**
   - A: Lists are per-character since v2.34.0. Each character has its own independent state. Use the Account Sell List (shared across all characters) for items you want every alt to vendor.
   - panel: nil (informational only)

6. **"How do I share a Sell List across all my characters?"**
   - A: Open the Account Sell List panel below. Items added there get unioned with each character's per-character Sell List at vendor time.
   - panel: `EbonClearanceOptionsAccountWhitelist`

7. **"The Goblin Merchant isn't being summoned when my bags fill up."**
   - A: Three things must all be true: `Summon Greedy Scavenger` is on, `Auto-Loot Cycle` is on, and you have the Greedy Scavenger / Goblin Merchant companion in your spellbook. Configure in the panel below.
   - panel: `EbonClearanceOptionsScavenger`

8. **"The bag-slot border tints aren't showing."**
   - A: Sell-border tints are off by default. Tick `Enable sell-border tints` in the panel below, then enable the per-category checkboxes you want to see (Delete / Account Sell / Character Sell / Junk / Rule).
   - panel: `EbonClearanceOptionsHighlighting`

9. **"How do I disable the addon on one specific character?"**
   - A: Right-click the minimap button on that character to toggle the addon off, or type `/ec` and use the toggle on the Main panel. The setting is per-character; other characters stay enabled.
   - panel: nil (`/ec` action, not a panel)

10. **"How do I see exactly why a bag item will or won't sell?"**
    - A: Alt+Shift+Right-Click the item, or type `/ec sellinfo` (defaults to the first non-empty bag slot). Prints the full predicate chain in chat.
    - panel: nil (diagnostic command)

## Seed entries for v1: Section 2 (Gates)

Section header: **"How sell decisions work"**. Default collapsed. Each entry explains one gate in the EC_IsSellable / BuildQueue chain. The text answers the `/ec sellinfo` trace step's question "what does this gate check?" without forcing the user to read source.

1. **"Order of checks"** - lists the gate sequence: hasSellPrice -> greyAutoSell / qualityRule / onSellList -> equippedVeto -> keepListVeto -> affixProtection -> chanceOnHitProtection -> tomeProtection. (panel: nil)
2. **"Grey items always sell"** - quality 0 + sellPrice > 0 is the unbreakable junk rule. Even with Sell List and quality rules off, junk vendors automatically. (panel: nil)
3. **"Items must have a vendor price"** - sellPrice == 0 items never auto-sell. Custom items, BoP soulbound rewards with no vendor value, etc. Use Delete List if you want them removed. (panel: nil)
4. **"Per-rarity quality rules"** - White / Green / Blue / Epic toggles in the Merchant Settings panel. Each is independently enable-able. (panel: `EbonClearanceOptionsMerchant`)
5. **"Fixed iLvl cap vs Use equipped iLvl"** - two cap modes per rarity. Fixed: items at or below the cap match. Use equipped: items below your currently-worn iLvl in the same slot match. (panel: `EbonClearanceOptionsMerchant`)
6. **"Bind-type filter"** - per-rarity restriction: Any / BoE only / BoP only. Useful if you only want to vendor BoEs while keeping BoPs. (panel: `EbonClearanceOptionsMerchant`)
7. **"Currently-equipped items never sell"** - even on the Sell List. EC won't vendor what you're wearing. Multi-spec wearers can use auto-protect-equipment-sets to also protect off-set gear in bags. (panel: `EbonClearanceOptionsProtection`)
8. **"Keep List veto"** - items on the Keep List are protected from every auto-sell rule. Manual Sell List adds do override quality rules but Keep List wins. (panel: `EbonClearanceOptionsBlacklist`)
9. **"PE affix protection"** - Project Ebonhold roguelite affixes on Rare/Epic items (e.g., "of Inner Light III"). The auto-rule sweep won't vendor these even when the rule would otherwise match. Override with Alt+Right-Click -> Allow Sell or the "Allow exact-rank duplicates" toggle. (panel: `EbonClearanceOptionsProtection`)
10. **"Allow exact-rank duplicates"** - bulk release: when you've already extracted an affix at this rank (per the spellbook or PE's catalog), drops of the same affix release the protection. v2.35.1: recognises ownership via description text match OR family + rank match. Stays a release gate, not a positive sell signal - items still need a quality-rule match or Sell List entry to vendor. (panel: `EbonClearanceOptionsProtection`)
11. **"Manual Allow Sell (Alt+Right-Click)"** - per-affix override. Marks the specific affix description as allow-listed; every future drop of that affix passes through the protection. Survives across characters (Account-wide). (panel: nil)
12. **"Chance-on-hit protection"** - PE proc spells extractable at the Anvil. Items with a `Chance on hit:` line are protected to preserve extraction options. Per-itemID Allow Sell (Alt+Right-Click) releases. (panel: `EbonClearanceOptionsProtection`)
13. **"Tome / recipe protection"** - spell-teaching items (Plans, Schematic, Patterns, Recipes, plus class tomes and mount scrolls). Hard-veto on the auto-rule path even when on the Sell List - requires Alt+Right-Click Allow Sell to override. (panel: `EbonClearanceOptionsProtection`)
14. **"Quest item safety net"** - GetItemInfo class `Quest` items never auto-sell via the quality rule, even if rule matches. Explicit Sell List adds DO override (your intent wins). (panel: nil)
15. **"Profession tool safety net"** - fishing poles, mining picks, Skinning Knife, Blacksmith Hammer, Arclight Spanner all hard-coded as protected. Explicit Sell List adds override. (panel: nil)
16. **"Delete List path"** - separate from sell. Items on Delete List are destroyed at the next merchant visit. Same affix protection applies; explicit Allow Sell releases. (panel: `EbonClearanceOptionsDeletion`)

## Seed entries for v1: Section 3 (Labels)

Section header: **"Tooltip label meanings"**. Default collapsed. One entry per label variant. Each `q` is the literal label text the user sees; the `a` explains what fires it.

1. **"Keep"** (no parens) - manual Keep List entry. Plain "Keep" means you added the itemID via Alt+Right-Click or the Keep List panel. (panel: `EbonClearanceOptionsBlacklist`)
2. **"Keep (equipped)"** - auto-protect-equipped fired. The item is on your currently-worn gear; EC adds equipped items to the Keep list automatically while you're wearing them. (panel: `EbonClearanceOptionsProtection`)
3. **"Keep (upgrade)"** - auto-protect-upgrades fired. The item's iLvl is above your currently-worn piece in the same slot. Stale entries auto-clean on subsequent BAG_UPDATEs. (panel: `EbonClearanceOptionsProtection`)
4. **"Keep (in gear set)"** - auto-protect-equipment-sets fired. The item is in one of your saved Blizzard Equipment Manager sets (e.g., off-spec gear). (panel: `EbonClearanceOptionsProtection`)
5. **"Keep (auto)"** - legacy generic auto-tag from pre-v2.12.0 saves. Functionally identical to one of the above; the specific origin tag was lost during an upgrade. (panel: `EbonClearanceOptionsBlacklist`)
6. **"Keep (quest item)"** - quest-item safety net fired. The item's class is `Quest`. (panel: nil)
7. **"Keep (profession tool)"** - profession-tool baseline list match. Fishing poles, mining picks, etc. Use Allow Sell (Alt+Right-Click) if you want to vendor a duplicate. (panel: nil)
8. **"Keep (affix rank known)"** - PE roguelite affix detected; you own this exact rank of the affix. Dupe-allow is off, so protection still holds. Turn on Allow exact-rank duplicates to let drops of owned ranks vendor. (panel: `EbonClearanceOptionsProtection`)
9. **"Keep (affix rank needed)"** - PE roguelite affix detected; you don't own this exact rank (either a new family or a different rank). The item is protected so you can extract the affix. (panel: nil)
10. **"Keep (chance-on-hit proc)"** - PE chance-on-hit proc detected. Protected from auto-sell so you can extract the proc spell. Alt+Right-Click -> Allow Sell on the item to release. (panel: `EbonClearanceOptionsProtection`)
11. **"Keep (new Tome)" / "Keep (new Recipe)"** - tome / recipe protection fired; you haven't learned the spell yet. Right-click the item to learn it. Dismiss the protection by toggling off in Protection Settings. (panel: `EbonClearanceOptionsProtection`)
12. **"Keep (Tome you have)" / "Keep (Recipe you have)"** - tome / recipe protection fired AND you've learned it. Requires "Protect all tomes / recipes" toggle on. Useful if you collect spares for AH or alts. (panel: `EbonClearanceOptionsProtection`)
13. **"Will Sell"** - Sell List entry match without quality-rule context. Plain label; the merchant cycle will vendor at next visit. (panel: `EbonClearanceOptionsWhitelist`)
14. **"Will Sell (your Account List)"** - Account Sell List match. The itemID is in `EbonClearanceAccountDB.whitelist` (shared across all characters). (panel: `EbonClearanceOptionsAccountWhitelist`)
15. **"Will Sell (your Character List)"** - per-character Sell List match. The itemID is in this character's `DB.whitelist`. (panel: `EbonClearanceOptionsWhitelist`)
16. **"Will Sell (junk)"** - grey item with positive sell price. Always sells regardless of other settings. (panel: nil)
17. **"Will Sell (Blue, ...)"** / **"Will Sell (Green, lower than equipped)"** / etc. - quality-rule match with rarity + cap context. The parenthetical tells you which rule fired and the iLvl context. (panel: `EbonClearanceOptionsMerchant`)
18. **"Will Sell (you have this affix)"** - autoDupe released the affix protection AND a positive sell signal exists (whitelist or quality rule). The item will vendor as a duplicate. (panel: `EbonClearanceOptionsProtection`)
19. **"Will Delete"** - Delete List match + Enable Deletion is on. Item will be destroyed at next merchant visit. (panel: `EbonClearanceOptionsDeletion`)
20. **"Won't Sell (equipped)"** - on the Sell List but currently worn. EC won't vendor equipped gear. Unequip first. (panel: nil)
21. **"Won't Sell (no value)"** - on the Sell List but the vendor price is 0. EC can't vendor items with no price. Try Delete List instead. (panel: `EbonClearanceOptionsDeletion`)
22. **"Override on - add to a list to sell"** - Allow Sell mark exists but the item isn't on any sell list and no rule fires. EC has nothing to release. Add to a Sell List to actually vendor. (panel: nil)

## Layout

```
[ panel-level Help heading + intro ]

[ chrome-wrapped scroll content area ]

  [-] Troubleshooting
      |cffffff00Why isn't this item selling?|r
      Alt+Shift+Right-Click the item, or /ec sellinfo, ...
                              [ Open Protection Settings -> ]
      ── separator ──
      |cffffff00The addon keeps adding my equipped gear ...|r
      ...

  [+] How sell decisions work             (collapsed; entries hidden)

  [+] Tooltip label meanings              (collapsed; entries hidden)
```

When the user clicks `[+] How sell decisions work`:

```
  [-] How sell decisions work
      |cffffff00Order of checks|r
      Each bag item runs through these gates in order: ...
      ── separator ──
      |cffffff00Grey items always sell|r
      ...
```

### Section header

- A `Button` spanning the chrome's full width minus the right scrollbar gutter.
- Shows `[+]` (collapsed) or `[-]` (expanded) glyph at the left, followed by the section title in `GameFontNormalLarge` yellow.
- Subtle hover highlight (vertex colour on the button's normal texture).
- OnClick toggles `DB.helpSectionsCollapsed[entry.section]`, then re-runs the build's anchor / show pass and calls `NS.FitScrollContent(content, lastVisibleWidget)`.

### Per-entry structure (inside an expanded section)

- **Title FontString** (`GameFontNormal`, yellow colour escape, full chrome-width, anchored TOPLEFT to previous-visible-widget's BOTTOMLEFT + 14 px).
- **Answer FontString** (`GameFontHighlight`, word-wrapped, full chrome-width minus right-padding for the optional button, anchored TOPLEFT to title's BOTTOMLEFT + 4 px).
- **Button** (UIPanelButtonTemplate, autosized to the panel display name + 24 px chrome, anchored TOPRIGHT to answer's BOTTOMRIGHT + 6 px) - only when `panel` field is set.
- **Separator** (`Texture`, low-alpha grey, full chrome-width minus 12 px insets, 1 px tall, anchored BOTTOMLEFT to button-or-answer's BOTTOMLEFT + 8 px).
- Spacing: 14 px between entries within a section, 22 px before the next section header.

### Chrome dimensions

Standard v2.32.x list-panel chrome (see `EbonClearance_ProcessBagsPanel.lua` and `EbonClearance_SellListPanels.lua` for prior art):

- Backdrop: `Interface\\Tooltips\\UI-Tooltip-Background` tile + `Interface\\Buttons\\WHITE8x8` edge at 1 px.
- Colours: `SetBackdropColor(0, 0, 0, 0.6)` + `SetBackdropBorderColor(0.2, 0.2, 0.2, 1)`.
- Insets: 6 px top / left / bottom, 28 px right (matches the v2.29.0 Import/Export pattern so the scrollbar gutter visually aligns).

Width tracking: every FontString + button registered via `EC_compCache.setPanelWidth(widget, 50)` (50 px reserved for chrome + scrollbar gutter) so they reflow on Interface Options panel resize.

## Hyperlink mechanism

The optional `[ Open <Panel> -> ]` button's OnClick:

```lua
local target = _G[entry.panel]
if target and InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(target)
    InterfaceOptionsFrame_OpenToCategory(target)
end
```

Standard double-call pattern (3.3.5a Interface Options quirk: first call registers the category focus, second call actually focuses). Same pattern as `EC_compCache.openPanelToList` in `EbonClearance_Events.lua`. Safe when the target panel doesn't exist (just no-ops via the nil guard).

The button's display label comes from the target panel's `name` field (e.g., `target.name = "Protection Settings"`), prefixed with `"Open "` and suffixed with `" ->"`. Looked up at OnClick time so a future panel rename doesn't require updating EC_HELP_ENTRIES.

## Discoverability

- **Sidebar entry**: visible whenever the user opens `/ec`. Browsing finds it.
- **Slash command**: existing `/ec help` chat output gains one line at the end:
  ```
  |cffffff00Open /ec -> Help|r for the in-game FAQ + troubleshooting panel.
  ```
- **README**: brief mention in the "Configuration" section adding "Help" to the panel list, plus a `/ec` -> `Help` callout in the "If something looks wrong" sub-section (or equivalent).

## Test additions

Added to `tests/test_perf_guardrails.lua`:

- **Test 71**: `EbonClearance_HelpPanel.lua` exists, is added to `SOURCE_PATHS` in the three test files, and is included in the release workflow's `cp` glob in `.github/workflows/release.yml`.
- **Test 72**: panel registration sanity - frame named `EbonClearanceOptionsHelp`, registered via `InterfaceOptions_AddCategory`, wrapped via `EC_compCache.initPanel`, scroll-wrapped via `NS.EC_WrapPanelInScrollFrame`.
- **Test 73**: `EC_HELP_ENTRIES` table is declared at file scope with three section markers (`troubleshooting`, `gates`, `labels`) and at least 30 content entries (10 troubleshooting + 14 gates + 17 labels, with some headroom for trims).
- **Test 74**: every content entry has both `q` and `a` fields (the `panel` field is optional). Catches typos / missing fields in the table on commit.
- **Test 75**: section-collapse state is partitioned per-character - `helpSectionsCollapsed` is in `PER_CHAR_FIELDS` so the v2.34.0 partition migrates it correctly (matches the `processCollapsedModes` precedent).
- **Test 76**: `/ec help` chat output includes the FAQ-panel mention (string match against the new line).
- **Test 77**: chrome-wrapping invariant - `applyBackdrop` (or the equivalent `SetBackdrop` calls with the project's standard tile + edge texture pair) is present in `EbonClearance_HelpPanel.lua` so the visual chrome doesn't accidentally drop during a future refactor.

## File-load order in .toc

The new file goes **last** in the .toc, after `EbonClearance_BagContextMenu.lua` (the current last entry). The panel registers `_G["EbonClearanceOptionsHelp"]`, but no other code references this name at file-load time - only the user's click on the sidebar entry uses it.

## Out of scope (v1)

Deferred-not-rejected so future work has clear hooks:

- **Search box** for the FAQ. ~10 entries fit in one scrolled view; search is premature. Revisit at ~25 entries.
- **Widget-level highlighting** (pulse the specific checkbox in the target panel when the user clicks "Open <Panel> ->"). Panel-level jump is enough for v1; widget-level highlighting requires a registry mapping FAQ entries -> widget refs that has to be kept in sync with every panel refactor.
- **Slash-command FAQ topics** (`/ec help <topic>`). One line in `/ec help` pointing to the panel is enough. Topic shortcuts are power-user-only; add later if asked.
- **Inline hyperlinks within answer text** (clickable `|H|h` patterns). The single right-aligned button per entry covers the navigation case; inline hyperlinks add a custom hyperlink handler and aren't worth the complexity for v1.
- **User-extensible FAQ** (saving custom notes). Out of scope; CHANGELOG / `/ec bugreport` cover that use case.
- **Per-locale content**. EC's L10n posture is enUS-only on Project Ebonhold per CLAUDE.md; defer along with any future L10n work.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| FAQ content drifts as the addon evolves (e.g., a panel renamed, a feature removed) and entries point to non-existent panels or describe stale behaviour. | The `_G[panel]` nil-guard prevents the click from erroring. The entry table is small and append-only; review on every release. The `q` text is the identifier so renames don't break entry tracking. |
| The 10 seed entries don't match the actual top-N user confusion cases. | Append-only data structure - adding/removing entries is a one-block diff. After ~2 releases with user feedback, prune the unused entries and add the actually-confused-about ones. |
| Panel grows past one screen and users have to scroll. | Already scroll-wrapped, so visually fine. Search box deferred to when count exceeds ~25 entries. |
| New player opens the panel as their first stop and finds it too dense. | The 10-entry set is tuned for "second visit, looking for an answer to something specific" rather than "first visit, what does this addon do?" The Main panel + first-run welcome popup cover the "what is this" case. Could add a one-line "First time? Start at /ec -> Main" hint at the top of the panel. (Bonus polish; not required for v1.) |
| User clicks "Open Protection Settings ->" and Interface Options re-opens; navigation can be jarring. | Same UX as the existing context-menu `Open <List> Panel` flow; users are familiar. Double-call pattern is the standard 3.3.5a quirk and well-tested across the codebase. |

## Implementation notes (for the plan)

- New file `EbonClearance_HelpPanel.lua` follows the same shape as `EbonClearance_ScavengerPanel.lua` (a non-list-management, mostly-text panel that's scroll-wrapped). Use that file as the structural template.
- The build callback (inside `EC_compCache.initPanel`'s build slot) iterates `EC_HELP_ENTRIES` once. Each iteration creates the three FontStrings + optional button + separator and anchors them to the previous entry's separator BOTTOMLEFT. A local `prevAnchor` variable threads the anchoring.
- After the loop, call `NS.FitScrollContent(content, lastSeparator)` so the scroll content grows to the bottom-most widget (matches every other scroll-wrapped panel).
- The button's display name lookup at OnClick time: `_G[entry.panel].name` returns the panel's display string ("Protection Settings", "Account Sell List", etc.). Falls back to `entry.panel` if `_G[entry.panel]` or its `name` field is missing (defensive against rename drift).
- `/ec help` body lives in `EbonClearance_Events.lua` near the slash-command handlers. The new line is a one-line append.
- README change is one bullet under "Configuration" and (optionally) a one-line callout under "Slash Commands" or a new "Troubleshooting" sub-section.

## Verification (in-game checklist for the implementation PR)

- [ ] `/ec` opens; sidebar shows `Help` as the last entry under EbonClearance.
- [ ] Clicking `Help` shows the panel. Three section headers are visible: `Troubleshooting` (expanded by default), `How sell decisions work` (collapsed), `Tooltip label meanings` (collapsed).
- [ ] Chrome backdrop wraps the scroll content area. Dark fill, thin grey border, scrollbar inside the right gutter (matches the Sell/Keep/Delete/Process Bags panels).
- [ ] Clicking `[+] How sell decisions work` expands the section; glyph flips to `[-]`. Entries appear, scrollbar lengthens to fit. Re-click collapses; entries hide, scrollbar shortens.
- [ ] Collapse state persists across `/reload` (saved to `DB.helpSectionsCollapsed`).
- [ ] Switching to a different character: sees the per-character collapse state (own defaults on first visit).
- [ ] Each content entry with a `panel` field renders a `[ Open <Panel Display Name> -> ]` button at the bottom-right.
- [ ] Clicking `[ Open Protection Settings -> ]` on the first troubleshooting entry swaps the Interface Options panel to Protection Settings.
- [ ] Entries without a `panel` field (e.g., #5, #9, #10 in troubleshooting; the diagnostic-only entries in gates / labels) have no button. Layout shifts cleanly.
- [ ] `/ec help` chat output includes the new line about the in-game FAQ panel.
- [ ] No `EbonClearance_*.lua` file errors at addon load. `EbonClearanceOptionsHelp` is a valid global frame after PLAYER_LOGIN.
- [ ] Test suite passes (all three invariant test files).
- [ ] `luac -p` clean on the new file.
