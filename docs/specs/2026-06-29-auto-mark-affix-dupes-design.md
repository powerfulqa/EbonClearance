# Auto-mark unsellable affix dupes - design

**Status:** built in v2.47.0 (pending in-game verification).
**Requested by:** Broyo (relayed). He has collected **all** affixes; while farming he gets affixed **soulbound** drops that are duplicates of affixes he already owns. They can't be auctioned/traded (soulbound) and many have no vendor value, so EC's affix protection just keeps them and they clutter his bags.

## Decision (value-aware, confirmed with the maintainer)

For an affixed item whose affix the player **already owns**:
- **Has a vendor price** -> left for the existing sell path ("Allow selling affixes you already have" / `affixAllowExactDupes` releases owned dupes so a quality rule / Sell List vendors them). The player keeps the gold.
- **No vendor price AND soulbound** -> **auto-mark to the Delete List** + a chat line. It then deletes via the normal Delete List flow (at a vendor, or instantly if auto-delete-on-pickup is also on).

Mechanism = **auto-mark to Delete List** (reversible/reviewable), mirroring the v2.44.0 resilience auto-mark, NOT a new instant-delete path.

## Implementation

- **DB:** `DB.autoMarkAffixDupes` (account-wide, default `false`), nil-default in `EnsureDB`.
- **Shared 3-layer ownership helper:** `EC_compCache.playerOwnsAffix(affix)` in `EbonClearance_Protection.lua` - description match OR family+rank OR family-only, mirroring `EC_IsSellable`'s `autoDupePass`.
- **Delete-path alignment:** `deleteListSlotEligible`'s `isDupe` was description-only; switched to `playerOwnsAffix` so the delete path recognises the same dupes the sell path (and the new scan) do. Without this, a rank/family-matched dupe would be marked but vetoed at delete time (marked-but-never-deleted). **EC-TRAP:** keep `playerOwnsAffix` in lockstep with `EC_IsSellable`'s `autoDupePass`.
- **Shared release helper:** `EC_compCache.affixDisposable(affix)` (Events.lua) returns true when affix protection RELEASES the affix - Allow Sell (ADB.allowedAffixes) OR owned exact-rank dupe with a dupe-disposal toggle on (`affixAllowExactDupes` or `autoMarkAffixDupes`) OR rank below the `affixMinSellRank` floor. Mirrors the release side of `EC_IsSellable`'s affix block. `deleteListSlotEligible` and the scan both call it (de-drift). 
- **Scan:** `EC_compCache.runAutoMarkAffixDupes()` runs from the BAG_UPDATE debounce (alongside `runAutoDeleteOnPickup` / `runAutoMarkResilience`). Gates: master Enable, `enableDeletion`, `autoMarkAffixDupes`, `protectAffixedRareItems`. Per slot, marks itemID to `DB.deleteList` (one per cycle + chat line) when: affixed (Rare/Epic), `affixDisposable(affix)` (EC would sell it - dupe OR below-floor), soulbound (`getBindType == "bop"`), no vendor value (`sellPrice` nil/<=0), and not Keep-listed / equipped / quest / tome / profession-tool.
- **UI:** child toggle on the Delete List panel (`EbonClearance_KeepDeletePanels.lua`) under the resilience auto-mark, greyed when "Allow items to be deleted" is off, with a note that it also needs affix protection on (Protection settings). No confirm popup (reversible mark, mirrors the resilience toggle).
- **Decoupled from `affixAllowExactDupes` (v2.47.0 iter, from Broyo's testing):** originally the scan required `affixAllowExactDupes` because the delete-path affix gate only released dupes when that "sell dupes" toggle was set - so the feature was inert for anyone who hadn't turned on a *sell* option, which is confusing for a *delete* feature. Now `deleteListSlotEligible` releases an owned dupe for deletion when EITHER `affixAllowExactDupes` OR `autoMarkAffixDupes` is on, and the scan no longer requires the sell toggle.
- **Exact-rank dupes by design (confirmed via Broyo's affixdebug dump):** `playerOwnsAffix` matches only the exact rank you've extracted. PE players collect individual ranks (the dump showed Iron Will I-V all extracted, but Stalwart V only). So a Stalwart IV drop for a player who has only Stalwart V is correctly NOT a dupe ("Keep (affix rank needed)") and must not be deleted - it's a rank still being collected. Do NOT broaden the *dupe* match to "outranked" (>= rank): it would destroy ranks the player is farming for.
- **Broadened to below-floor (v2.47.0 iter 2, from Broyo's `/ec sellinfo`):** the original scan only marked exact-rank dupes. But Broyo's stuck item (Relentless Crits III, soulbound, sellPrice 0) was a rank *below* his `affixMinSellRank=4` floor that he doesn't own - so it wasn't a dupe, but his rank floor flagged it "WILL SELL" (a positive sell signal that ignores sell price), the merchant refused it (no price), and it was never deleted. The fix: the scan marks anything `affixDisposable` releases (dupe OR below-floor), so unsellable below-floor affixes get deleted instead of stuck. Below-floor deletion is safe + intended: the floor IS the player's "I don't want these ranks" signal. Help entry calls out this interaction so it doesn't surprise.

## Bind-type-aware dupe disposal (v2.47.0 iter 3, from Broyo's testing)

An out-ranked-Unique attempt (iter 3a) was **built then reverted**. It auto-sold a soulbound Unique affix the player owned at a higher rank (e.g. Temporal Flux IV when you have V). In testing it confused the maintainer (the "out-ranked" concept wasn't intuitive) and didn't address what Broyo actually wanted: a split by **bind type**. The maintainer chose a simpler, ownership-based rule instead and explicitly rejected handling out-ranked ranks. The out-ranked helpers (`playerOutgrewAffix`, `affixIsUnique`, `playerHasAffixRankAtLeast`, `AFFIX_UNIQUE_MARKERS`), the `sellOutrankedAffixes` toggle, `outrankedPass`, the tooltip "out-ranked" label, and Test 103 were all removed.

### The rule (maintainer-chosen)

For an affixed Rare/Epic item whose affix the player **already owns** (the existing exact-rank `playerOwnsAffix` / `autoDupePass` 3-layer check):
- **Soulbound + has vendor value -> vendor it** (sell path).
- **Soulbound + no vendor value -> delete it** (the existing `autoMarkAffixDupes` scan - already soulbound-only, already works).
- **Bind-on-equip -> KEEP it** so the player can auction it themselves.

Broyo's two failing cases were: soulbound owned dupe with value (wanted vendor) and BoE owned dupe with value (wanted to keep for AH). EC had no bind-type split anywhere - "Allow selling affixes you already have" sold BOTH (his "sells both at vendor"), and with it off neither sold (his "keeps both").

### Implementation
- **DB:** `DB.keepBoeAffixDupes` (account-wide, default `false`, nil-default in `EnsureDB`). `true` = keep bind-on-equip owned dupes (sell only soulbound ones); `false` = today's behaviour (sell all owned dupes regardless of bind). Default preserves existing behaviour for current users.
- **The gate:** when `DB.affixAllowExactDupes` releases an owned dupe AND `DB.keepBoeAffixDupes` is on, the release only holds for **soulbound** items (`getBindType == "bop"`). BoE / unknown-bind owned dupes stay protected (kept). Reuses the existing dupe detection; no new ownership concept.
- **Sell path (`EC_IsSellable`):** the gate is applied to BOTH the positive-signal `autoDupePass` AND the affix-veto-release `autoDupe`. Both are needed: if only `autoDupePass` were gated, a BoE owned dupe that also matches a quality rule would pass the positive check via `qualityPass` and then the un-gated veto `autoDupe` would release it -> it sells. Gating both keeps the veto and the sell signal in agreement.
- **Honesty mirrors:** the tooltip (`EbonClearance_Tooltip.lua`, `autoDupe` via `getBindTypeFromTooltip`) and the `/ec sellinfo` trace (`EbonClearance_BagDisplay.lua`) apply the same bind gate, so a kept BoE dupe never shows "Will Sell" and the trace explains why it's kept (Broyo debugs with `/ec sellinfo`). **EC-TRAP:** keep the bind gate in lockstep across `EC_IsSellable` (x2), the tooltip, and the trace.
- **Process Bags (DE / mill / prospect) is out of scope:** it's a separate explicit action; its affix guard is unchanged (the bind split is about vendor-vs-auction, not disenchant).
- **UI:** child checkbox **"Keep bind-on-equip ones (auction them yourself)"** indented under "Allow selling affixes you already have" in the Protection panel, greyed by the same gate as the parent dupe toggle (parent off / PE not detected). Default off.

### Why not handle out-ranked ranks (Temporal Flux IV when you own V)?
The maintainer chose exact-rank ownership only. So a lower rank of a Unique affix you've maxed stays **kept**, not sold. Documented so it doesn't surprise: "you own it" means the rank that dropped, not "you own a higher rank."

## Tests
`tests/test_perf_guardrails.lua` Test 102 (a-g): default-false DB seed, `playerOwnsAffix` 3-layer helper, `deleteListSlotEligible` uses it (alignment lock), scan gating, scan predicate (owned + soulbound + no-value + protections skipped), debounce wiring, panel checkbox.

Test 103 (a-e, the bind-type split): default-false `keepBoeAffixDupes` seed; `EC_IsSellable` gates BOTH `autoDupePass` and the veto `autoDupe` on `keepBoeAffixDupes` + `getBindType == "bop"`; the tooltip and `/ec sellinfo` trace mirror the gate; the Protection panel renders the child checkbox writing `DB.keepBoeAffixDupes`.

## Known limitation
The Delete List is itemID-granular but affixes are per-instance. Marking the itemID is safe because `deleteListSlotEligible` re-applies the affix gate per instance (a future instance of that itemID with an affix the player does NOT own is still protected and won't delete). The only theoretical leak is a non-affixed instance of a marked itemID; for PE affixed gear that itemID effectively always drops affixed, so it's a corner case.

## Out of scope
- Selling vendorable dupes (existing `affixAllowExactDupes` + quality-rule / Sell List).
- Instance-accurate instant delete (the maintainer chose mark-to-list).
