# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?style=for-the-badge&label=Download&color=orange)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads (this release)](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FEbonClearance%2Fbadge-data%2Flatest.json&style=for-the-badge&color=blue)](https://github.com/powerfulqa/EbonClearance/releases/latest)
[![Downloads (lifetime)](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FEbonClearance%2Fbadge-data%2Fdownloads.json&style=for-the-badge&color=blue)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)

**Full bags, every quest hub, every farm session. EbonClearance handles the chore.**

Sells what you don't want. Keeps what you do. Knows the difference because it reads your Project Ebonhold affix and proc state directly. Zero config to start, one click for a guided setup, deep controls when you want them. No external libraries, stock Blizzard 3.3.5a APIs only.

## How it sells

- **Per-rarity auto-sell rules** (Common / Uncommon / Rare / Epic). Caps follow your equipped iLvl, or set a fixed max. Bind-type filter per rarity.
- **Sell, Keep, and Delete lists**, per-character and account-wide. Bulk-add from your bags by colour, switch lists by activity with saved profiles.
- **Settings profiles (v2.72.0).** Each character picks a named profile holding its selling behaviour - merchant mode, rarity rules, protections, affix and recipe settings, deletion toggles, vendor speed. Alts on the same profile share it live; save a new profile to give one alt its own rules. (Before v2.72.0, these settings were silently shared account-wide.)
- **Sell known recipes** you've already learned, opt-in and per-rarity (Common / Uncommon / Rare / Epic). Per-rarity bind-type filter too (Any / BoE only / BoP only) so you can sell BoE patterns alts won't use while keeping the BoP ones. Learn-state is read per-character, so each alt only sells the patterns it already knows; unlearned ones stay safe.
- **Tooltip says what will happen** before you vendor. `/ec sellinfo` traces every decision, and Alt+Right-Click → **Sell Info** gives the same trace for one item, so "why isn't this selling?" is one click away.

## What it protects

- **Affixed Rare/Epic drops.** Affix-keyed Allow-Sell overrides for the ones you've decided you don't need.
- **Chance-on-hit procs you haven't extracted yet**, plus tomes and recipes you haven't learned. Class-aware: bows on Druids and relics on Mages stay off your Keep List. When you've extracted a weapon proc at the Anvil, an experimental toggle in Keep Settings lets extra copies auto-sell (v2.49.0). Coverage grows automatically: v2.49.1's autolearn spots each Anvil extraction and pairs the itemID with the PE spellID so future drops of that weapon are covered without a code change. **Guild-share (v2.53.0)** takes this further: opt in and your addon quietly pools chance-on-hit pairings with opted-in guildmates so you inherit their extractions too. Anonymous - the wire never carries who taught you what; only the pairings themselves.
- **Quest items, equipped gear, equipment-manager set members.** Each protection has an Alt+Right-Click → Allow Sell override.

## The loop

- **Greedy Scavenger summon** with auto-rebuy and dismiss-on-mount. Heavy-combat safe.
- **Goblin Merchant + Fast Loot.** Throttled drain so private-server anti-flood doesn't disconnect you.
- **Process Bags panel** for disenchant / mill / prospect / pick-lock. Bind a key, hold to drain a stack.

A complete enumeration of every feature lives in [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md). Behaviour history is in [CHANGELOG.md](CHANGELOG.md). For the design lineage, see [NOTICE.md](NOTICE.md).

## Installation

1. Head to the [latest release](https://github.com/powerfulqa/EbonClearance/releases/latest) and download the zip file.
2. Extract the `EbonClearance` folder into your `Interface/AddOns` directory.
3. Log in and type `/ec` to open the settings panel.
4. Sensible defaults are seeded for new characters - Common and Uncommon auto-vendor below your equipped iLvl, equipped gear is auto-Kept, the Scavenger / auto-loot cycle are on. Tune from there.

Per-character on/off: tick / untick the **Enable EbonClearance** checkbox at the top of the main panel, right-click the minimap button, or type `/ec enable` / `/ec disable` to skip the addon on alts you'd rather it leave alone. Use `/ec status` to check the current state at any time.

## Configuration

All settings live under `/ec`, which opens the scrollable config panel. Highlights:

- **Lists.** Sell List, Account Sell List, Keep List, Delete List. One "Add item" field takes an item ID or a name (exact, or part of a name to add matching items from your bags); the Sell Lists also have by-quality bulk-add buttons. Rows show the item icon and a quality-colored name; hover a row for the item tooltip. Filter the view by name or rarity, and sort by name. The Delete List has an optional "auto-delete on pickup" toggle (off by default) that destroys listed items the moment they're looted, to cut vendor trips while farming. It can also auto-mark soulbound affix duplicates you already own that have no vendor value (off by default), leaving sellable dupes for the merchant. Also on the Delete Settings panel: **Auto-delete grey items on loot** (opt-in, off by default) destroys grey (quality 0) drops the moment they hit your bags for players who prioritise bag space over vendor copper (it skips keep-listed items, equipped gear, quest items, and pauses while a merchant is open). The main EbonClearance panel adds **Warn about conflicting addons** (on by default), which shows a popup at login (naming the detected addon) when a conflicting bag-management addon is running alongside EC.
- **List Profiles.** Save / load / rename / clear the Sell + Keep list pairs. Default profile is locked empty.
- **Settings Profiles.** Named selling-behaviour profiles each character picks independently (see above). Save the current settings under a name, press **Use** on another character to share them, or keep alts on different profiles. Deleting a profile moves its users back to Default. Item lists, stats, looting, and visual options are not included.
- **Merchant Settings.** Per-rarity quality thresholds with `Use equipped iLvl` or fixed-max-iLvl cap, per-rarity bind-type filter, merchant target (Goblin / normal vendors / both), Fast Mode toggle, vendor sell speed, summon delay. Also here: **Sell recipes you already know** (opt-in, per-rarity with a bind-type filter), which auto-sells learned profession recipes (unless "keep all tomes" is on, which wins).
- **Keep Settings.** Auto-protect equipped gear, looted upgrades, equipment-manager sets, affixed Rare/Epic items (including unranked Project Ebonhold transferred procs like Vampirism / Resurgence), chance-on-hit items, tomes / recipes (with optional extension to already-known items). Affix-sell controls: "Allow selling affixes you already have" (with an opt-in sub-option **"Keep bind-on-equip ones (auction them yourself)"** - vendors only the soulbound dupes, keeps the BoE ones for the auction house) and a **"Sell affixes below rank" floor** (ranges 0 - VI as of v2.52.0, for Project Ebonhold's rank VI affix scaling). New in v2.49.0: **Sell known chance-on-hit procs (experimental)** - once you've extracted a weapon's proc at the Anvil, extra copies of that weapon auto-sell (v2.49.1's autolearn grows the coverage from your own extractions).
- **Scavenger Settings.** Summon controls, chat / speech-bubble mute, auto-loot cycle threshold, auto-open containers, Fast Loot.
- **Process Bags.** Disenchant / mill / prospect from your bags; per-skill on/off toggles (untick a skill and the same keybind skips it; only skills your character can do are shown), configurable DE rarity cap, Soulbound inclusion toggle, per-character ignore list.
- **Import / Export.** Sell List sharing strings, per-section source/target.
- **Item Highlighting.** Toggle the bag-slot sell-border tint per category (Delete / Keep / Account Sell / Character Sell / Known Affix / Needed Affix / Junk / Rule), pick each category's colour through the standard colour-picker dialog, opt into the item-level overlay (with sub-toggles for bags / character sheet & inspect / merchant + a font-size slider), and optionally show the numeric item ID on bag-item tooltips. v2.52.0 split the previous single "Random affix" tint into two complementary categories: **Known Affix items (purple)** fires when the item carries an affix you already own at rank/family/description; the new **Needed Affix items (gold)** fires when the affix is one you haven't extracted yet - an at-a-glance extraction target. (Per-character on/off lives on the minimap button + `/ec`, not in a panel.)
- **Statistics.** Lifetime + session counters side-by-side, reset independently. Includes per-rarity breakdowns of sells and deletions, top-5 most-sold and most-deleted items, lifetime Process Bags counters (Disenchant / Mill / Prospect / Pick Lock), and a top-zones leaderboard by lifetime gold earned at vendor. **Stats - Guild** pools opted-in guild/group members anonymously; **Stats - Server** (on by default as of v2.59.1; uncheck the panel toggle to opt out) is a realm-wide "collective odometer" showing the combined, anonymous totals of everyone online and sharing right now (gold vendored, items sold/deleted/processed, busiest zones, most-sold items, live sharer count) - not a leaderboard, never names. It rides a hidden chat channel (one channel slot while sharing is on) and can also carry realm-wide update alerts.
- **Loot Log.** A resizable window (`/ec loot`, the main-panel or Stats-panel **Loot Log** buttons, or a key binding) listing everything you've looted, how many, its vendor value, and that value's share of the gold in the current view - so you can see which drops earn and which are dead weight worth filtering or auto-deleting. Sort by name, count, or gold (count and gold diverge when a high-volume drop is low-value), narrow the list by rarity or by typing in the search box, and right-click a row to hide that item so it stops skewing the shares (Unhide All restores them). Filtering rebases the totals, so filtering to Epics shows each Epic's share of your Epics. Counts what you actually loot - your own loot, the auto-loot cycle, and the Greedy Scavenger's haul - and ignores items you buy, mail, withdraw from the bank, or get from quests. Three views: Session (this login), Character (this character's lifetime), Account (all characters). Alt+hover a row for EbonClearance's verdict on that item. Tallied per item, so it stays light no matter how long you farm.
- **Sold History.** A window (`/ec history`, the main-panel **Sold History** button, or Alt+Right-Click any bag item) listing everything sold or deleted this session and the plain-English rule that decided it, newest-first. Since v2.73.0 it also records deletes that happened *outside* EbonClearance (a manual drag-delete, another addon) with a clear "outside EbonClearance" label, excluded from your stats - so a missing item can always be traced. Filter by **All / Sold / Deleted**, narrow by rarity, search by item name or reason, and **Copy** the current view for a Discord paste. The three filters combine. Records the whole session (v2.57.0 raised it from the old 20-entry cap to the full session), so nothing is lost during a long farm; session-only, clears on `/reload`.
- **Updates.** "Tell me when an update is available" toggle on the main panel (on by default). EbonClearance learns the newest version from other users in your guild or group and shows one chat line with a clickable copy-link. The newest version seen also stays on the main panel, on its own line under the toggle, so you can check it any time instead of having to catch the one chat line.
- **Key Bindings (WoW).** Open settings, toggle enabled, force sell at current merchant, open/close the Loot Log, Process Next.
- **Minimap button.** Left: options, Middle: Process Bags, Right: toggle.
- **Alt+Right-Click any bag item** for a quick-action menu (add to Sell / Keep / Delete, Allow Sell on protected items, **Sell Info** for a per-item sell-decision trace, and **Sold History** for this session's sell/delete log).
- **Help / FAQ panel** with a keyword search box - type a term to filter the FAQ to matching entries.

## Slash Commands

| Command | Description |
|---------|-------------|
| `/ec` | Open the settings panel |
| `/ec status` | Show whether EbonClearance is currently enabled or disabled |
| `/ec enable` | Turn EbonClearance on for this character |
| `/ec disable` | Turn EbonClearance off for this character |
| `/ec profile list` | Show all saved Sell List profiles |
| `/ec profile save <name>` | Save the current Sell List as a named profile |
| `/ec profile load <name>` | Load a saved profile into the active Sell List |
| `/ec profile delete <name>` | Delete a saved profile |
| `/ec sprofile list` | Show all settings profiles and who uses them |
| `/ec sprofile save <name>` | Save this character's selling settings as a named profile and use it |
| `/ec sprofile use <name>` | Switch this character to a settings profile |
| `/ec sprofile delete <name>` | Delete a settings profile (users switch to Default) |
| `/ec clean` | Report any item IDs present in more than one list |
| `/ec clean apply` | Auto-resolve list conflicts using precedence Keep List > Delete List > Sell List |
| `/ec clean upgrades` | Report stale `Keep (upgrade)` Keep List entries that are no longer above your equipped iLvl (v2.33.1+ auto-cleans these on every bag update; this command is now mainly for one-shot inspection) |
| `/ec clean upgrades apply` | Manually remove stale `Keep (upgrade)` entries (with confirmation) |
| `/ec bugreport` | Generate a comprehensive diagnostic report (Issue Summary at top, recent sold / deleted / silent-refusal ring buffers, toggle diffs, last-event times, cache stats, addon list partitioned into potentially-relevant + other). Opens in a resizable copyable window. |
| `/ec sellinfo [bag slot]` | Trace why a bag item will or won't sell - per-predicate chain trace (also via Alt+Shift+Right-Click, or Alt+Right-Click → Sell Info) |
| `/ec loot` | Open the Loot Log window (Session / Character / Account views, rarity filter and search box; also main-panel and Stats-panel buttons and a bindable key) |
| `/ec history` | Open the Sold History window: everything sold or deleted this session and the rule that decided it, newest-first, with All / Sold / Deleted filters, a rarity filter, a search box, and a Copy button. Records the whole session (not just the last few); session-only, clears on `/reload` |
| `/ec rules` | Open a plain-English summary of every active rule + the order EC applies them (also the "Current Rules" button on the Main panel) |
| `/ec minimap on\|off\|reset` | Show, hide, or re-centre the EC minimap button (use `off` if it clashes with a minimap-replacement / magnifier addon) |
| `/ec affixdebug on\|off\|status\|dump\|clear` | Record affix-detection events for bug reports; `dump` opens a copyable window with the event log |
| `/ec processdebug` | Diagnostic: open a copyable window listing every Process Bags gate (recognised profession spells, per-slot scan results) for bug reports |
| `/ec scandebug <bag> <slot>` | Diagnostic: dump the hidden scan-tooltip lines for a bag slot (for "this item silently sells despite having an affix or proc" reports) |
| `/ec captureproc` | Diagnostic: dump every bag item's chance-on-hit line + every extracted-affix spell tooltip + the full PE learnedAffixes catalog, for building the runtime chance-on-hit-proc translation table |
| `/ec autolearnsim <itemID> <spellID>` | Diagnostic: simulate an autolearn event (needs item in bags). |
| `/ec autolearnpeek` | Dump the chance-on-hit autolearn state (author + autolearn + ambiguous). |
| `/ec perf` | Show EbonClearance's memory, CPU, cache and list sizes |
| `/ec spike` | Show recent frame hitches EbonClearance contributed to and which phase (bag update / vendor / tooltip) was busiest during each, in a copyable window (session-only, clears on `/reload`) |
| `/ec bubbles` | Diagnostic: show what the Scavenger bubble mute tracked from chat vs the bubble texts seen on screen, with match verdicts, in a copyable window (session-only, clears on `/reload`) |
| `/ec affixfallback on\|off\|status` | Diagnostic: force EbonClearance to ignore Project Ebonhold's affix data and read learned affixes from your spellbook only, to verify affix protection survives if that data source ever changes (session-only, clears on `/reload`) |
| `/ec commtest` | Diagnostic: check that addon messages are delivered on this server and preview the update nudge (works solo) |
| `/ec guildtest` | Diagnostic: preview the Stats - Guild panel with simulated members (works solo) |
| `/ec procsharetest` | Diagnostic: inject three fake chance-on-hit pairings into `ADB.chanceProcConfirmedItems` through the real merge path (v2.53.0). Confirms the guild-share pipeline works solo. |
| `/ec locale [auto\|frFR\|deDE]` | Show or force the addon's display language. `auto` follows your client; a code forces that language (handy when your client is locked to one language). `/reload` to apply fully |
| `/ec help` | Print the full slash-command reference in chat |
| `/ecdebug` | Show debug info and run a bag scan |

## Requirements

- World of Warcraft (WotLK client, Interface 30300)
- Project Ebonhold server

## For Contributors

Working on the addon? There's developer documentation under [docs/](docs/):

- [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is the prescriptive guide for coding in this addon. Read it first: it covers 3.3.5a client gotchas, the file's architecture, naming conventions, the state machine, UI patterns and the decision not to embed Ace3.
- [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md) is a short list of known follow-up cleanups that weren't part of the last pass.

- [docs/TRANSLATING.md](docs/TRANSLATING.md) is the guide for translating the addon into your language. French (`frFR`) and German (`deDE`) ship substantially complete; other languages start from the French template.

A Luacheck config ([.luacheckrc](.luacheckrc)) and a StyLua formatter config ([stylua.toml](stylua.toml)) are checked in. Run `stylua --check *.lua` and `luacheck *.lua` before opening a PR. (The addon ships as 37 `.lua` files after the v2.32.0 file-split, the v2.36.0 Help / Stats panel splits, the v2.38.0 Quickstart panel, the v2.39.0 `EbonClearance_Comms.lua` addition, the v2.40.0 guild-share files, the v2.43.0 localization files, the v2.53.0 `EbonClearance_ProcShare.lua` addition, the v2.57.0 `EbonClearance_HistoryWindow.lua` addition, and the v2.58.0 realm-wide sharing files (`EbonClearance_RealmComms.lua`, `EbonClearance_ServerShare.lua`, `EbonClearance_ServerStatsPanel.lua`); the entry hub is `EbonClearance_Events.lua`.)

## Thanks

Feature ideas and bug reports from the Project Ebonhold community shape the addon. Selected community-driven changes:

- **Auto-delete on pickup** - suggested by Sanavesa.
- **Auto-mark PvP gear (Resilience) for deletion** - requested by Murlocked, for cleaning up bag-clutter after farming.
- **Class-restriction self-heal on the Keep-Upgrade sweep** (Druids no longer accumulate bows, Mages no longer accumulate relics) - reported by Murlocked.
- **Auto-mark unsellable affix dupes for deletion** - requested by Broyo.
- **Announce auto-delete / auto-mark in chat** toggle - requested by ayres.
- **2H-narrowing on the upgrade / downgrade predicates** (1H weapons and offhands compare correctly against an equipped 2H instead of misfiring on the locked-empty offhand slot) - reported by "Perfect Bidoof" and Zukii.
- **Hard iLvl ceiling on the affix-sell paths** (a rare high-iLvl item can't sneak past a rarity cap just because its affix is a known dupe) - near item-loss report from Bizzaro.
- **Quickstart Q13 default label fix + Stats-Guild "Sold by Quality" alignment** - reported by Qvintus.

## Changelog

Per-release notes live in [CHANGELOG.md](CHANGELOG.md). For prior-art acknowledgement and the design lineage, see [NOTICE.md](NOTICE.md).

## Notice

EbonClearance ships in a niche where similar inventory-management addons exist for the same private server. [NOTICE.md](NOTICE.md) documents prior art and convergent patterns honestly: which structural elements (the source-available licence shape, the provenance globals form) are adopted from conventions already present in the 3.3.5a addon ecosystem, and which (the fingerprint and watermark mechanism) are specific to this project. Read it before drawing conclusions about influence in either direction.

## Licence

This project is distributed under the EbonClearance Source-Available Attribution Licence. You may use, modify, and redistribute the addon (including in private-server addon-pack bundles) provided you preserve the author credit, the in-game byline, the provenance globals, and the LICENSE file itself, and you do not silently rebrand the addon name, the `/ec` slash command, the SavedVariable names, or the `EC:` import/export prefix. Forks under a new name are welcome as long as attribution to the original author and source URL is preserved. See the [LICENSE](LICENSE) file for the full terms.
