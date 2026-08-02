# Architecture (code map)

A bird's-eye map of where things live, for a contributor or AI agent landing
in the repo. This is a map, not a manual: it tells you which file to open, not
how every function works. For the deep reference (3.3.5a constraints, gotchas,
refactoring traps, comms/guild-share internals) read
[ADDON_GUIDE.md](ADDON_GUIDE.md). For deferred work, read
[CODE_REVIEW.md](CODE_REVIEW.md).

EbonClearance is a WoW 3.3.5a (WotLK, Lua 5.1) bag manager: it vendors, deletes,
loots, protects items by rule, and runs profession processing. No external
libraries; all Blizzard APIs.

## How the files fit together

The `.toc` ([EbonClearance.toc](../EbonClearance.toc)) is the load-order source
of truth; the list below groups those files by role, not load order. Every file
starts with `local NS = select(2, ...)` and shares state through that `NS`
table. The only true globals are `EbonClearanceDB`, `EbonClearanceAccountDB`,
the slash-command handles, and the `EbonClearance_*` keybind handlers called
from `Bindings.xml`.

### Engine (no UI)

| File | Owns |
|------|------|
| [EbonClearance_Core.lua](../EbonClearance_Core.lua) | Provenance/fingerprint, shared "junk-drawer" state, `STATE` constants, the `NS` bootstrap, and the `EnsureDB` / `EnsureAccountDB` SavedVariables migrations. Loads first; depends on nothing. |
| [EbonClearance_Decision.lua](../EbonClearance_Decision.lua) | The sell/keep/delete decision core (v2.71.0-v2.71.3). `NS.Decision.sell(ctx)` and `NS.Decision.deleteEligible(ctx)` are PURE (no WoW API, no DB) and return verdicts + reason tokens; two adapters (`buildCtx` for bag slots, `buildTooltipCtx` for hovers/chat links) share one snapshot helper. `EC_IsSellable` + `deleteListSlotEligible` in Events delegate here. Runtime-tested by `tests/test_decision.lua`. |
| [EbonClearance_Companion.lua](../EbonClearance_Companion.lua) | The Greedy Scavenger companion: summon/dismiss, chat + speech-bubble filtering, pet-check OnUpdate. |
| [EbonClearance_Protection.lua](../EbonClearance_Protection.lua) | What to *keep*: PE roguelite affix + chance-on-hit detection and the affix-data cache. |
| [EbonClearance_Vendor.lua](../EbonClearance_Vendor.lua) | The vendor cycle: `BuildQueue` / `DoNextAction` / `worker`, plus the `EC_Effective*` pacing helpers. |
| [EbonClearance_Process.lua](../EbonClearance_Process.lua) | The Process Bags engine: Disenchant / Mill / Prospect / Lockpick. |
| [EbonClearance_BagDisplay.lua](../EbonClearance_BagDisplay.lua) | Bag-slot sell-border tint + the sellinfo inspector (host bag UI adapter). Since v2.71.1 the inspector's verdict comes from `Decision.sell`; only the per-step narration is local. |

### Event hub & comms

| File | Owns |
|------|------|
| [EbonClearance_Events.lua](../EbonClearance_Events.lua) | The single event frame, the `/ec` slash commands, and the residual glue. Adding an event = `RegisterEvent` + a branch here, never a new frame. Also where every Interface Options panel is registered centrally. |
| [EbonClearance_Comms.lua](../EbonClearance_Comms.lua) | `NS.Comms` addon-to-addon transport + the version-update gossip. |
| [EbonClearance_GuildShare.lua](../EbonClearance_GuildShare.lua) | Opt-in, anonymous-by-default guild/group stats sharing (a `NS.Comms` consumer). |
| [EbonClearance_ProcShare.lua](../EbonClearance_ProcShare.lua) | Opt-in, anonymous chance-on-hit proc-pairing sharing across the guild (a `NS.Comms` consumer, v2.53.0). |
| [EbonClearance_RealmComms.lua](../EbonClearance_RealmComms.lua) | `NS.RealmComms` - a hidden-chat-channel transport sibling of `NS.Comms`, because 3.3.5a `SendAddonMessage` cannot reach the whole realm (v2.58.0). |
| [EbonClearance_ServerShare.lua](../EbonClearance_ServerShare.lua) | The realm-wide anonymous stats odometer (a `NS.RealmComms` consumer). Aggregates per sender, so a re-send never double-counts. |

### Interface Options panels (feature UI)

One file per panel (or closely-related pair). All register centrally in
`Events.lua`; none self-registers.

[MainPanel](../EbonClearance_MainPanel.lua) ·
[MerchantPanel](../EbonClearance_MerchantPanel.lua) ·
[ScavengerPanel](../EbonClearance_ScavengerPanel.lua) ·
[ProcessBagsPanel](../EbonClearance_ProcessBagsPanel.lua) ·
[SellListPanels](../EbonClearance_SellListPanels.lua) ·
[KeepDeletePanels](../EbonClearance_KeepDeletePanels.lua) ·
[ProtectionPanel](../EbonClearance_ProtectionPanel.lua) ·
[ItemHighlightingPanel](../EbonClearance_ItemHighlightingPanel.lua) ·
[ProfilesPanel](../EbonClearance_ProfilesPanel.lua) (hosts List Profiles, Settings Profiles, and Import/Export) ·
[StatsPanel](../EbonClearance_StatsPanel.lua) ·
[GuildPanel](../EbonClearance_GuildPanel.lua) ·
[ServerStatsPanel](../EbonClearance_ServerStatsPanel.lua) ·
[QuickstartPanel](../EbonClearance_QuickstartPanel.lua) ·
[HelpPanel](../EbonClearance_HelpPanel.lua)

### Panel infrastructure (shared widgets)

| File | Owns |
|------|------|
| [EbonClearance_PanelInfra.lua](../EbonClearance_PanelInfra.lua) | The panel-width registry + reactivity layer (`EC_compCache`). Any widget that snapshots panel width MUST go through it. |
| [EbonClearance_PanelWidgets.lua](../EbonClearance_PanelWidgets.lua) | Panel widget primitives, plus `NS.MakeStatRow` - the shared two-column stat row (`row.left` / `row.right` at a fixed value X) every stats surface uses so numbers stack in a column. Also `NS.MakeRarityDropdown` and the two z-order helpers (`NS.RaiseDropDownAbove`, `NS.RaiseTooltipAboveWindows`) that any TOOLTIP-strata pop-out needs - see the EC-TRAP notes there before adding a dropdown or tooltip to one. |
| [EbonClearance_ListWidget.lua](../EbonClearance_ListWidget.lua) | The reusable list-management widget (add input / search / sort / rarity filter). |

### Localization

| File | Owns |
|------|------|
| [EbonClearance_Locale.lua](../EbonClearance_Locale.lua) | The `NS.L` lookup layer (v2.43.0). Resolves per-lookup, not copied at load, so `/ec locale <code\|auto>` switches live. Loads right after Core. |
| [EbonClearance_Locale_frFR.lua](../EbonClearance_Locale_frFR.lua) · [EbonClearance_Locale_deDE.lua](../EbonClearance_Locale_deDE.lua) | Translation templates. The English string IS the key; an empty value falls back to English. See [TRANSLATING.md](TRANSLATING.md). |

Player-facing strings are wrapped at the call site as `L["English text"]`
(`local L = NS.L`). `tests/test_locale_coverage.lua` fails the build if a new
`L[]` key has no slot in both templates, so a string cannot ship untranslatable.

### Other UI & utility

| File | Owns |
|------|------|
| [EbonClearance_Minimap.lua](../EbonClearance_Minimap.lua) | Minimap button, LDB launcher, combat-vendor button. |
| [EbonClearance_Tooltip.lua](../EbonClearance_Tooltip.lua) | Bag-item tooltip annotations. Since v2.71.2 it reads all state through `Decision.buildTooltipCtx` and its labels are guarded by `Decision.sell`'s verdict (equipped-honesty fix-up + sentinel line); only the per-branch label text is local. |
| [EbonClearance_BagContextMenu.lua](../EbonClearance_BagContextMenu.lua) | Alt+Right-Click bag-item quick-action popup. |
| [EbonClearance_BugReport.lua](../EbonClearance_BugReport.lua) | Diagnostic snapshot builder + display frame (`/ec bugreport`). |
| [EbonClearance_HistoryWindow.lua](../EbonClearance_HistoryWindow.lua) | The interactive Sold History window (`/ec history`, v2.57.0): full-session sell/delete log with All/Sold/Deleted filters + search, over `NS.recentSoldLog` / `NS.recentDeletedLog`. |

`Bindings.xml` defines keybinds that call the `EbonClearance_*` global handlers.

## Boundaries (the things that must stay true)

These are the invariants an agent should not "simplify" across. Many are pinned
in code with `EC-TRAP:` markers; run `grep -rn "EC-TRAP:"` before touching
anything that looks like dead code or a bug.

- **One event frame.** It lives in `Events.lua`. Features do not create their own.
- **Cross-file state goes through `NS`.** New globals are not added.
- **SavedVariables change only via `EnsureDB` / `EnsureAccountDB`** nil-default
  migrations (downgrade-safe, additive). Both live in `Events.lua` (the
  `EnsureDB` body around the per-char field list; `Core.lua` owns the namespace
  shape, not the migrations).
- **PE-only settings gate on `EC_compCache.peFeaturesVisible()`** (Protection),
  never on `peDetected()` alone, and never at
  `InterfaceOptions_AddCategory` time. Hiding a setting that defaults ON also
  needs a runtime gate, or the stored value keeps driving behaviour with the
  off-switch invisible. Full rules in ADDON_GUIDE.
- **Chat output only through `PrintNice` / `PrintNicef`.** Never
  `DEFAULT_CHAT_FRAME:AddMessage` directly.
- **Panel width only through `EC_compCache`** (PanelInfra), or it freezes at
  build-time width on resize.
- **State transitions use `STATE.*` constants,** not raw strings.
- **No third-party addon names** in new code, docs, or player-facing text.
- **No em dashes (U+2014) anywhere.**

## Where do I make change X?

| I want to... | Open |
|--------------|------|
| Change what counts as sellable / keepable | `Decision.lua` (the sell/keep core; add a fixture in `tests/test_decision.lua`) + `Protection.lua` for detection helpers |
| Change vendor pacing / per-run cap | `Vendor.lua` (`EC_Effective*` helpers) |
| Add a profession-processing rule | `Process.lua` |
| Add a settings checkbox | the relevant `*Panel.lua` + an `EnsureDB` default in `Events.lua` |
| Hide a setting on a realm without the affix system | gate it on `EC_compCache.peFeaturesVisible()`, add its FAQ entry to `EC_PE_HELP_IDS` in `HelpPanel.lua`, and add a runtime gate too if it defaults ON |
| Add a whole new options panel | new `*Panel.lua` + register it centrally in `Events.lua` |
| React to a new game event | `RegisterEvent` + a branch in `Events.lua` (not a new frame) |
| Add a `/ec` subcommand | the slash handler in `Events.lua` (and a row in `README.md`) |
| Change a bag border or tooltip annotation | `BagDisplay.lua` / `Tooltip.lua` |
| Send an addon-to-addon message | `NS.Comms` in `Comms.lua` |
| Add or align a row on a stats surface | `NS.MakeStatRow` in `PanelWidgets.lua`; the refresh body lives in `MainPanel.lua` (`NS.RefreshStats`) |

## Verifying a change

From the repo root:

```
lua tests/run_all.lua          # all eleven invariant suites in one shot
luac -p EbonClearance_*.lua     # syntax check every shipped file (luac5.1 in CI)
luacheck *.lua                  # 0 warnings expected (runs in CI; see CLAUDE.md)
```

CI ([.github/workflows/test.yml](../.github/workflows/test.yml)) runs the syntax
check, luacheck, and `tests/run_all.lua` on every push; the release workflow
re-runs them at the tag gate. See [CLAUDE.md](../CLAUDE.md) for the full release
process.
