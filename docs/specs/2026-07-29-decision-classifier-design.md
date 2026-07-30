# Decision classifier: one sell/delete verdict source behind reason tokens

Status: Stage 0 (design). Target: v2.71.0+ as staged, bisectable releases.
Origin: docs/CODE_REVIEW.md audit item 6 (trigger fired twice on 2026-07-11),
confirmed by the 2026-07-29 competitive review (Tier A1) against a sibling
addon that ships the working pattern on 3.3.5a: pure, WoW-free decision
modules returning a verdict plus a machine-readable reason token, with every
surface rendering from that one source.

## Problem

The sell decision is implemented three times in parallel (EC_IsSellable in
EbonClearance_Events.lua, describeSellability in EbonClearance_BagDisplay.lua,
EC_AnnotateTooltip in EbonClearance_Tooltip.lua), and the delete-side
previews mirror deleteListSlotEligible + the auto-mark gates the same way.
The paired-edit discipline is pinned by EC-TRAPs and Tests 117/118, but
drift has caused two field incidents (one a near item-loss) and every new
sell condition costs three edits plus test lockstep. Separately, 8 of 10
test suites are static-pattern checks; the actual decision logic has no
runtime coverage.

## Shape

New file `EbonClearance_Decision.lua` (loads early, after Core; needs
nothing at load time) containing two layers:

1. **Pure core** - plain-Lua functions that read ONLY a `ctx` table:
   - `NS.Decision.sell(ctx) -> verdict, token, fields`
   - `NS.Decision.deleteEligible(ctx) -> eligible, token, fields`
   - No WoW API calls, no DB reads, no EC_compCache reads, no locale reads.
     Everything arrives pre-captured in ctx. This is what makes the core
     loadable under stock lua5.1 in the test suite.
2. **Adapter** - `NS.Decision.buildCtx(bag, slot, opts)` does every WoW /
   DB / cache read exactly once per decision: GetContainerItemID/Info,
   GetItemInfo, list memberships (via NS.IsInSet), the rule tables, and
   the lazy tooltip-backed predicates (getBindType, bagSlotAffixData,
   itemHasChanceOnHit, itemIsTome, playerKnowsTomeSpell, resilience) -
   reusing the existing cached accessors so scan cost does not change.

The verdict is one of `"sell" | "keep" | "none"` for the sell family and a
boolean for delete eligibility; `token` is the canonical reason;
`fields` carries render data (rule quality, cap, affix name/rank, list
origin tag, etc.) so surfaces can format without re-deriving.

## Token vocabulary (v1)

Positive sell signals (existing lastSellSignal values, unchanged so the
Sold History reasons keep working): `whitelist_char`, `whitelist_account`,
`recipe`, `knownproc`, `affixrank`, `autodupe`, `junk`, `quality`.

Keep/veto tokens (superset of Tooltip's statusTag vocabulary so Stage 3 is
a rename, not a re-derivation): `blacklist`, `equipped`, `set`, `upgrade`,
`quest`, `baselineTool`, `affixknown`, `affixneeded`, `chanceonhit`,
`tomeLearned`, `tomeUnlearned`, `highIlvl` (auto-mark guard), `noValue`,
`ceiling` (affixSaleWithinCeiling veto), `savedRuleChange` (drain-time,
already shipped in v2.70.0), plus `none` (no rule fired).

Delete-side tokens: `deleteList`, plus veto tokens shared with the keep
family (the delete gate refuses on keep/sell-list membership, equipped,
affix protection, quest).

Rule: tokens are append-only once shipped; renderers must tolerate unknown
tokens with a neutral fallback label (future-proofing, same contract the
itemProtectedFromAutoMarkDelete reason tuple established in v2.60.0).

## Staging (each stage its own release, full gate + in-game mirror pass)

- **Stage 1 (v2.71.0):** ship the file + pure core mirroring EC_IsSellable
  EXACTLY (the vendor engine is ground truth), + `tests/test_decision.lua`
  as the 11th suite: loads the pure core WoW-free with fixture ctxs
  covering every token, including golden regression cases from the field
  incidents (the ilvl-277 ceiling near-loss; Pattern: Mooncloth Leggings
  whitelist-vs-tome; the knownProcPass-only Rare weapon). EC_IsSellable
  delegates: buildCtx + Decision.sell + the existing return shape
  preserved (sellable, link, itemID, sellPrice, itemCount, quality);
  lastSellSignal written from the returned token. Behaviour identical;
  Tests 110k/117 keep passing against the delegating wrapper.
- **Stage 2 (v2.71.x):** describeSellability renders its trace from
  buildCtx + Decision.sell (token + fields -> existing step labels). The
  trace-specific narration (per-step n/a lines) keys off ctx + token.
- **Stage 3:** EC_AnnotateTooltip renders from the token; statusTag
  BECOMES the token (the v2.43.0 statusTag EC-TRAP was designed for
  exactly this). Label map lives in Tooltip.lua, keyed by token.
- **Stage 4:** delete side - deleteListSlotEligible delegates to
  Decision.deleteEligible; the auto-mark preview + tooltip Will Delete
  labels render from its tokens; retire the paired-edit EC-TRAPs and
  convert Tests 117/118's mirror pins into single-source pins.

## Constraints and risks

- **Lazy-cache capture:** buildCtx must trigger the same lazy fills the
  current predicates do (scanItemMarkers, bagSlotAffixData) so cold-item
  behaviour (retry-until-rendered, never cache from empty tooltips) is
  unchanged. The ctx snapshots VALUES, not accessors.
- **Grey-always-sold invariant:** the core keeps the three independent
  passes (isJunk / qualityPass / whitelistPass); the EC-TRAP moves onto
  the core with the code. Test fixtures pin it at runtime for the first
  time.
- **200-locals:** the new file starts fresh - keep its main chunk lean
  anyway (the Events lesson).
- **Load order:** Decision.lua loads after Core, before consumers resolve
  it at call time (lazy NS lookups; the Test 41 trap applies).
- **Registration checklist:** .toc, CLAUDE.md file count + suite list,
  tests/run_all.lua (11th suite), ARCHITECTURE.md table, ADDON_GUIDE
  file-layout + gotchas (mirror-contract section rewritten per stage).
- **Stage 5b interplay:** this extraction subsumes the pinned vendor-cycle
  split's main motivation (the decision core leaves Events.lua).
  Re-evaluate the residual worker/BuildQueue/StartRun move after Stage 4.
