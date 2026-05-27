# Help links across settings panels + Stats panel split

**Status:** approved, ready for implementation plan
**Date:** 2026-05-27
**Companion specs:** [2026-05-26-help-faq-panel-design.md](2026-05-26-help-faq-panel-design.md) (the Help panel that this work cross-references), [2026-05-26-gph-stats-design.md](2026-05-26-gph-stats-design.md) (the stats widgets being relocated)

## Motivation

Now that the Help panel exists with five organised sections (Getting Started, Troubleshooting, How sell decisions work, Tooltip labels, Reporting bugs), every settings panel duplicates explanations that the Help panel already covers. The Protection Settings page in particular has multi-line notes under every toggle, which:

- Makes the panel dense and intimidating for a new player
- Drifts from the canonical Help text over time as one is edited and the other isn't
- Leaves no room for the panel to grow new controls

Separately, the Main panel currently mixes welcome content with a tall stack of stat widgets (Money, Items Sold, Items Deleted, Repairs, Repair Cost, Session GPH, Best GPH + zone + when, Avg Worth, Most Sold, Reset Lifetime). Adding any further stat (per-session-totals, gold/hour graphs, etc.) is constrained by the available vertical space and visually crowds the welcome text a new player should be reading first.

This spec addresses both:

1. Move stats to their own panel; Main becomes welcome + orientation
2. Replace duplicated panel explanations with `[?]` icons that deep-link to specific Help entries

## Part 1: Stats panel split

### New panel: `EbonClearanceOptionsStats`

- Frame name: `EbonClearanceOptionsStats`, parent `EbonClearance`, `name = "Stats"`
- Registered with `InterfaceOptions_AddCategory` in the order list between Main and Merchant Settings
- File: keep the stats widgets in `EbonClearance_MainPanel.lua` (rename/repurpose, or split into a new `EbonClearance_StatsPanel.lua`). Implementation plan decides which is cleaner; spec is neutral
- All stat widgets move: `statsMoney`, `statsSold`, `statsDeleted`, `statsRepairs`, `statsRepairCost`, `statsSessionGPH`, `statsBestGPH` (+ zone + when sub-line), `statsAvgWorth`, `statsMostSold`, `statsNote`, and the `EbonClearanceResetStatsBtn` button
- `RefreshStats` (currently in `EbonClearance_Events.lua`) finds the new panel's widgets instead of Main's; uses the same `panel.statsX` attachment pattern so the function body is largely unchanged

### Main panel becomes welcome + orientation

After the move, Main shows only:

- Heading (`MakeHeader(self, "EbonClearance", -16)`)
- Welcome text (`Welcome to |cffb6ffb6EbonClearance|r - bag management for Project Ebonhold.`)
- Feature list (current `descLabel2` content: out-of-the-box junk selling, Sell List, Keep List, Merchant Settings, Process Bags hooks)
- The "tip" line about Alt+Right-Click
- Slash command list (`cmdText`)
- Addon-enabled toggle (currently lives on Main; stays there)

Visual rhythm: the Main panel reads like a landing page; Stats reads like a dashboard.

### `RefreshStats` re-wiring

Pre-condition: `RefreshStats` looks up `_G["EbonClearanceOptionsMain"]` and writes to its `statsX` attachments. Post-condition: it looks up `_G["EbonClearanceOptionsStats"]` for those writes. The ItemLabel warmup callback in `MainPanel.lua` (which schedules a `RefreshStats` after `GetItemInfo` cold cache settles) keeps its current behaviour but points at the new panel.

If the user opens Main and then opens Stats, the cached values render immediately — no recompute on every panel show; `RefreshStats` runs on the relevant data-change events (vendor close, BAG_UPDATE, etc.) and on the Stats panel's `OnShow` so a fresh visit picks up the latest values.

### Sort order

Registered sub-panel order:

1. Main (welcome)
2. **Stats** (new)
3. Merchant Settings
4. Protection Settings
5. Scavenger Settings
6. Item Highlighting
7. Sell List
8. Account Sell List
9. Keep List
10. Delete List
11. Process Bags
12. Profiles
13. Import/Export
14. Help

### Testing

- `lua tests/test_perf_guardrails.lua` invariants 22, 23 currently pin "MainPanel writes DB.bestGPH" etc. Update these to assert against the new panel file (or against a neutral "the stats writer panel") so the v2.35.0 GPH invariants survive the move.
- New test asserts `EbonClearanceOptionsStats` is registered.
- New test asserts the stats fontstring globals exist after panel build.

## Part 2: `[?]` help-links across settings panels

### Entry IDs in `EC_HELP_ENTRIES`

Each content entry in `EbonClearance_HelpPanel.lua` gains an optional `id = "stable-kebab-key"` field. Section markers do **not** get ids (they're not link targets). Sample mapping:

```lua
{
    q = "Currently-equipped items never sell",
    a = "Even when on the Sell List, EbonClearance won't vendor anything you're currently wearing. ...",
    id = "equipped-never-sells",
    panel = "EbonClearanceOptionsBlacklistSettings",
},
```

IDs are stable identifiers used by settings-panel `[?]` icons. Renaming the player-facing `q`/`a` doesn't break links. A test asserts every id is unique and that every id referenced by a settings panel exists in `EC_HELP_ENTRIES`.

### `[?]` icon widget

Helper exposed as `NS.AddHelpIcon(parent, anchorWidget, anchorPoint, xOffset, yOffset, entryId)`:

- Creates a `Button` (or invisible-frame + clickable FontString) anchored to `anchorWidget` at the given `anchorPoint`
- Renders `|cffffff00[?]|r` (yellow, matching the section glyphs in the Help panel)
- Hover highlights to brighter yellow + sets a `GameTooltip` showing "Open Help: <entry q-text>"
- `OnClick`: calls `NS.OpenHelpEntry(entryId)` and plays the standard checkbox sound

Width ~18px including padding. Height matches the parent widget's height where possible (so it aligns vertically with a checkbox or dropdown row).

### `NS.OpenHelpEntry(entryId)` API

New function exposed from `EbonClearance_HelpPanel.lua`:

```lua
function NS.OpenHelpEntry(entryId)
    -- 1. Find the renderItem with matching id (and the section it belongs to).
    --    If no match, fall through to step 4 only (open panel, no scroll).
    -- 2. Set DB.helpSectionsCollapsed[ownerSection] = false so the section is expanded.
    -- 3. Stash the pending-scroll target: HelpPanel._pendingScrollEntryId = entryId.
    -- 4. Call InterfaceOptionsFrame_OpenToCategory(HelpPanel) twice
    --    (the standard 3.3.5a workaround for the open-to-sub-panel bug).
    -- 5. After refreshLayout runs (called from OnShow), check
    --    HelpPanel._pendingScrollEntryId. If set: locate the matching
    --    renderItem's widget, compute its Y position relative to the
    --    OUTER scroll frame (the one created by EC_WrapPanelInScrollFrame
    --    in initPanel), and set scrollFrame:SetVerticalScroll(...) so
    --    the entry sits at the top of the viewport. Always scroll to top,
    --    regardless of whether the entry was already partially visible -
    --    consistent behaviour beats clever-but-fragile.
    -- 6. Clear HelpPanel._pendingScrollEntryId.
    -- 7. Briefly flash the target entry (0.5s yellow tint pulse on the
    --    q FontString via NS.Delay + SetTextColor) so the player's eye
    --    lands on it.
end
```

The OUTER scroll frame (referenced in step 5) is named `EbonClearanceOptionsHelpScroll` per `EC_WrapPanelInScrollFrame`'s naming convention. It's already a known frame in the Help panel build callback (the existing code re-anchors its scrollbar there). `SetVerticalScroll` is the standard `UIPanelScrollFrameTemplate` API.

Scroll math: `targetY = chromeOuter:GetTop() - entryWidget:GetTop()` gives the relative offset from chrome top to entry top. Clamped to the scroll frame's `verticalScrollRange` so the scroll doesn't overshoot the content's bottom.

If `entryId` is nil or no matching entry exists, the call still opens the Help panel without scrolling. Safe failure mode for typos and stale ids during development.

The flash effect uses the existing `NS.Delay` helper for the 0.5s timeout. No new timer infrastructure.

### Per-panel `[?]` placement

Every dense settings panel gets a `[?]` per setting or per logical group. The mapping is part of the implementation plan, but a representative sample:

| Panel | Setting / Group | `[?]` links to entry id |
|---|---|---|
| Protection Settings | "Keep gear you're wearing" toggle | `equipped-never-sells` |
| Protection Settings | "Keep looted upgrades" toggle | `keep-upgrade-label` |
| Protection Settings | "Keep gear sets" toggle | `keep-in-gear-set-label` |
| Protection Settings | "Allow exact-rank duplicates" toggle | `allow-exact-rank-duplicates` |
| Protection Settings | "Protect chance-on-hit" toggle | `chance-on-hit-protection` |
| Protection Settings | "Protect tomes / recipes" toggle | `tome-recipe-protection` |
| Merchant Settings | "White / Green / Blue / Epic" rarity rows | `quality-rules` |
| Merchant Settings | Fixed iLvl / Use equipped iLvl mode picker | `fixed-vs-equipped-ilvl` |
| Merchant Settings | Bind-type filter dropdown | `bind-type-filter` |
| Scavenger Settings | "Summon Greedy Scavenger" toggle | `goblin-not-summoning` |
| Item Highlighting | "Enable sell-border tints" group | `bag-borders-not-showing` |
| Process Bags | Mode picker / general intro | `process-bags-overview` |
| Process Bags | Disenchant mode | `process-disenchant` |
| Process Bags | Mill mode | `process-mill` |
| Process Bags | Prospect mode | `process-prospect` |
| Process Bags | Pick Locks mode | `process-picklocks` |
| Sell List | Top of panel | `what-are-the-lists` |
| Keep List | Top of panel | `what-are-the-lists` |
| Delete List | Top of panel | `what-are-the-lists` |
| Account Sell List | Top of panel | `share-sell-list-across-chars` |
| Profiles | Top of panel | New entry (Profiles overview) |
| Import/Export | Top of panel | New entry (Import/Export overview) |

### New Help entries to add

To support the [?] links, add these new entries to `EC_HELP_ENTRIES`. Process Bags is user-facing functionality that doesn't fit into the existing "Sell decisions" section (it's not a sell decision), so it gets its own section.

**New Section 6 — "Process Bags"** (section key `processBags`, inserted after `discord` or as a new section between `labels` and `discord` — the implementation plan picks a position):

- "What does Process Bags do?" (id: `process-bags-overview`) — short overview of the four modes + how to arm the cursor + cooldown behaviour
- "Disenchant mode" (id: `process-disenchant`) — Enchanting required, what items qualify
- "Mill mode" (id: `process-mill`) — Inscription, herbs
- "Prospect mode" (id: `process-prospect`) — Jewelcrafting, ore
- "Pick Locks mode" (id: `process-picklocks`) — Rogues, lockboxes

**Existing sections** (Getting started, Troubleshooting, How sell decisions work, Tooltip labels, Reporting bugs) get `id` fields added to each entry but no new content. Existing collapse-state defaults stay (every section collapsed by default).

`PER_CHAR_FIELDS.helpSectionsCollapsed` gets a new default key for `processBags`; existing characters' saved tables get the defensive default-true behaviour the OnShow already provides.

### Panel description simplification

The strip pass works on each settings panel:

- **Remove**: descriptive sentences explaining *what a setting means* or *why it exists* if the Help panel covers it. Example: the "Allow exact-rank duplicates" toggle currently has a 3-line note about "Bulk release: when you've extracted...". After: just the toggle label + `[?]`.
- **Keep**: one-line action guidance that helps the player *use* the panel (e.g. "Add items by Alt+Right-Click on a bag item or by typing the item ID below" on Keep List).
- **Keep**: panel-level intro / heading text (1-2 sentences max).

A "before/after" example for the Protection Settings panel: today it has roughly 12-14 explanation lines beneath the toggles; after the pass it has 2-3 lines total (panel description + maybe one tip), plus a `[?]` on every toggle.

### Cross-link integrity test

`tests/test_perf_guardrails.lua` gets new checks:

**Test 78** — Cross-reference integrity:
- Scans every settings panel file for `NS.AddHelpIcon(...)` calls
- Extracts the `entryId` string argument
- Asserts every referenced id appears as `id = "..."` in `EbonClearance_HelpPanel.lua`
- Fails the build if a panel references a missing or removed help id

**Test 73 update** — bump expected section markers from 5 to 6 (the new `processBags` section). The existing test pattern lists all section keys; add `processBags` to the list.

**Test 79** — Every Help entry has a unique id (no duplicates), and every id is non-empty. Catches copy-paste mistakes when adding new entries.

These catch drift when someone removes a Help entry without updating the panels that link to it, or adds an entry without an id, or accidentally reuses an id.

### Migration ordering

Because the spec touches every settings panel, the implementation plan should sequence per-panel migration with verification between each, not bundle them. Order: Protection Settings (densest, validate the pattern) → Merchant Settings → Scavenger Settings → Item Highlighting → Process Bags → list panels → Profiles → Import/Export.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Aggressive strip removes action-guidance the player needed | Keep one-line action descriptions; only remove "why/what does this mean" content. Reviewer reads the panel post-strip and asks "could a player still figure out how to use this?" |
| Help entry ids drift, breaking links silently | Test 78 cross-checks every referenced id against `EC_HELP_ENTRIES`. Build fails on missing ids. |
| Deep-link scroll math wrong on first open (FontStrings haven't computed heights yet) | Use the same `NS.Delay` two-pass pattern that `EC_FitScrollContent` uses. Compute scroll target at 0.1s and 0.5s after panel show; the second pass corrects any height settling. |
| Stats panel split breaks `RefreshStats` for existing characters | The function reads `panel.statsX` attachments; just swap which panel owns them. SavedVariables format unchanged. Existing characters see no data loss. |
| Flash effect causes a visible "jump" if the entry was already visible | Only flash; never auto-scroll if the entry is already in the viewport. Compute viewport-relative position first; skip scroll if already visible. |

## Out of scope

- Auto-discovering panel descriptions to strip (manual decision per panel)
- Hover tooltips on every setting (the [?] click is the explicit mechanism; we don't double up)
- Localisation (text is English-only, matches existing addon)
- A "Back to Settings" button in the Help panel after deep-link (player uses the Open Settings button or the InterfaceOptions left-nav)
- Search inside the Help panel
- Reordering existing help entries (the spec extends EC_HELP_ENTRIES; it doesn't reshuffle)

## Acceptance criteria

1. New `EbonClearanceOptionsStats` panel registered between Main and Merchant Settings, holds every stat widget, `RefreshStats` writes to it
2. Main panel shows welcome + orientation only (no stats)
3. New "Process Bags" Help section exists with the 5 entries listed above, all with stable ids
4. Every settings panel covered in the mapping table has a `[?]` icon per setting/group
5. Clicking any `[?]` opens the Help panel, auto-expands the right section, scrolls the target entry to the top of the viewport, briefly flashes the entry
6. Protection Settings and Merchant Settings panel files are visibly shorter after the strip pass (lines of explanation text drop by ~50% on these two)
7. Test 73 updated to expect 6 section markers; Tests 78 (cross-reference) and 79 (id uniqueness) pass
8. All existing tests (1-77) continue to pass after the migration
9. `stylua *.lua && luacheck *.lua` clean
10. Manual smoke test: brand-new character, no SavedVariables, opens settings; the panel reads cleanly and the [?] icons make discovery obvious
