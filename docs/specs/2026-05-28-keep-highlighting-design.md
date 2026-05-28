# Keep List bag-border highlighting (v2.37.0)

## Goal

Visual reassurance. A player about to vendor at a merchant glances at their bags and sees a distinct border on every item they manually added to the Keep List. The mental model: "the addon knows I want to keep this; it's not going anywhere."

This is the complement of the existing sell-side highlighting: red borders flag items being destroyed, gold/green/cyan borders flag items being sold, and the new Keep border flags items being explicitly protected by player choice.

## Non-goals

- No per-verdict colors. Equipped, upgrade-tagged, affix-protected, quest, bind-protected items do NOT get the Keep border. Those are addon decisions, not user reassurance targets. (User intent at brainstorm: "Keep List entry (manual)" only.)
- No icon overlays. The per-slot icon is untouched (existing constraint).
- No new infrastructure. The existing sell-border system is generic over per-category enable + color; Keep slots in as a sixth category.

## Surface

Reuses `EC_compCache.applySellBorder` and the weak-keyed `EC_compCache.sellBorderButtons` registry. No new rendering code path, no new hook into ContainerFrame_Update or the host bag-UI adapter.

## Resolver priority

Inserted in `EC_compCache.bagSlotWillSellCategory` (EbonClearance_BagDisplay.lua) AFTER the Delete-List check and BEFORE the `NS.IsSellable` bail:

1. Delete List (`DB.deleteList` + `DB.enableDeletion`) -> `"delete"`
2. **Manual Keep List (`DB.blacklist` AND NOT `DB.blacklistAuto`) -> `"keep"`** (new)
3. `NS.IsSellable` false -> return nil
4. Account Sell List -> `"accountSell"`
5. Character Sell List -> `"charSell"`
6. Junk -> `"junk"`
7. Quality rule -> `"rule"`

### Why insert before the IsSellable bail

Keep-listed items return false from `NS.IsSellable` (that's how the protection works). The existing resolver bails to nil for non-sellable items. Inserting the Keep check before that bail is the minimum change that surfaces the verdict.

### Manual vs auto

`DB.blacklist` is the union: it contains both manual adds AND auto-protected entries (equipped gear, upgrade matches, equipment-manager sets). `DB.blacklistAuto[itemID]` is the marker for auto-tagged entries ("equipped", "upgrade", "set"). The Keep category check is:

```lua
IsInSet(DB.blacklist, itemID) and not DB.blacklistAuto[itemID]
```

This excludes auto-protected items from the Keep border. Reasoning: those reflect the addon's decisions, not the player's. The reassurance use case is "show me what *I* told you to keep."

### Delete-on-both edge case

`EC_AddItemToList` conflict-guards multi-list adds, so an item cannot end up on both Delete and Keep lists via the normal paths. Defensively, the Delete check fires first in the resolver, so Delete wins if both are somehow set (consistent with the v2.37.0 Delete-wins fix in `BuildQueue`).

## Settings surface

One new row in the Item Highlighting panel (`EbonClearance_ItemHighlightingPanel.lua`). The panel's `SELL_BORDER_CATEGORIES` table is iterated to build enable-checkbox + swatch + color-picker per entry; appending `{ key = "keep", label = "Keep List (white)" }` is the entire panel change.

Insert position in `SELL_BORDER_CATEGORIES`: second (right after `delete`), matching the resolver priority.

## Defaults

```lua
keep = { enabled = false, color = { r = 0.95, g = 0.95, b = 1.00, a = 0.9 } },
```

- **enabled = false.** Diverges from every other category default (which all ship `enabled = true`). The reasoning: every existing player upgrading to v2.37.0 already has the sell-border feature configured the way they want; adding a NEW category that fires automatically would paint new tints on their bags without their action. Defaulting Keep to off keeps the upgrade visually silent - the player has to tick the row to opt in. Matches the v2.37.0 principle of "don't change existing players' setups without their action". The master `sellBorderEnabled` toggle is also off by default for the same reason.
- **color = soft cool white** (`r=0.95, g=0.95, b=1.00, a=0.9`). Distinct from the existing palette (red, bright green, cyan/sky blue, low-alpha grey, gold). Reads as "pristine / protected" without competing with the warm-toned sell verdicts. User-repaintable via the per-row Change-colour button.

## Help entry

Update `tshoot-bag-borders` in `EbonClearance_HelpPanel.lua` to mention the new Keep category in the list of borders the feature paints. The header bullet ordering should match the panel's row order (delete, keep, accountSell, charSell, junk, rule).

## Tests

Add to `tests/test_perf_guardrails.lua`:

- **Test 87**: `EC_DEFAULTS` (or equivalent init code) sets a default for `DB.sellBorderCategories.keep`. Static-pattern check on the `CAT_DEFAULTS` table in `EbonClearance_Events.lua`.
- **Test 87a**: `EC_compCache.bagSlotWillSellCategory` checks the manual Keep List between the Delete-List check and the `NS.IsSellable` call. Position-of-pattern check inside the function body.
- **Test 87b**: Item Highlighting panel registers a `"keep"` category row. Static-pattern check on `SELL_BORDER_CATEGORIES` in `EbonClearance_ItemHighlightingPanel.lua`.
- **Test 87c**: Help entry `tshoot-bag-borders` mentions Keep. Static-pattern check on the entry body.

## Save-variables compatibility

`DB.sellBorderCategories.keep` is a fresh key. The EnsureDB block at lines 1004-1052 of EbonClearance_Events.lua iterates `CAT_DEFAULTS` and lazily fills missing entries, so existing saves auto-migrate on first load post-v2.37.0. No explicit migration code needed.

Downgrade safety: a v2.36.x or earlier client reading the SV ignores unknown `sellBorderCategories.keep` keys; the resolver returns nil for slots that would have matched, so the worst case is "Keep border disappears on the older client" - no data corruption.

## What it does NOT do

- No upgrade-tagged border.
- No equipped-tagged border.
- No affix-protected border.
- No per-verdict colors beyond the single Keep entry.
- No automatic enabling for new users beyond the existing category-defaults pattern.
- No changes to the tooltip annotation, the EC_IsSellable predicate chain, or BuildQueue.

Pure visual-reassurance feature, scoped tight.
