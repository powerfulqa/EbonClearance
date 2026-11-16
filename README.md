# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?style=for-the-badge&label=Download&color=orange)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads (this release)](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FEbonClearance%2Fbadge-data%2Flatest.json&style=for-the-badge&color=blue)](https://github.com/powerfulqa/EbonClearance/releases/latest)
[![Downloads (lifetime)](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FEbonClearance%2Fbadge-data%2Fdownloads.json&style=for-the-badge&color=blue)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)

**Full bags, every quest hub, every farm session. EbonClearance handles the chore.**

Sells what you don't want. Keeps what you do. Knows the difference because it reads your Project Ebonhold affix and proc state directly. Zero config to start, one click for a guided setup, deep controls when you want them. No external libraries, stock Blizzard 3.3.5a APIs only.

Runs on any 3.3.5a server. On a realm without Project Ebonhold's affix system, the PE-only settings hide themselves and the rest works as usual (see [Other 3.3.5a servers](#other-335a-servers)).

## Getting started

**Needs:** a WotLK 3.3.5a client (Interface 30300). Project Ebonhold for the affix and proc features; everything else runs on any 3.3.5a server.

1. Download [EbonClearance.zip](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip) from the latest release.
2. Extract the `EbonClearance` folder into `Interface/AddOns`.
3. Log in and type `/ec`.

New characters start with sensible defaults: Common and Uncommon items below your equipped item level are sold, equipped gear is kept, and the Scavenger and auto-loot cycle are on. The **Quickstart** asks a few questions and sets the rest.

To leave an alt alone, untick **Enable EbonClearance** at the top of the main panel, right-click the minimap button, or type `/ec disable`.

## How it sells

- **Rules per rarity** (Common / Uncommon / Rare / Epic). Cap by your equipped item level or a fixed maximum, and filter by bind type.
- **Sell, Keep and Delete lists**, per character and account-wide. Bulk-add from your bags by quality; save list pairs as profiles and switch them by activity.
- **Settings profiles.** Each character picks a named profile for its selling behaviour. Alts on the same profile share it live.
- **Sell recipes you already know**, per rarity and bind type. Each alt only sells the patterns it has learned.
- **The tooltip says what will happen** before you reach a vendor. Alt+Right-Click an item and pick **Sell Info** to see exactly why it will or won't sell.

## What it protects

- **Affixed Rare and Epic drops**, with per-affix overrides for the ones you don't need.
- **Chance-on-hit procs you haven't extracted yet**, plus tomes and recipes you haven't learned. Class-aware, so Druids don't hoard bows. EbonClearance learns each extraction you make at the Anvil, and can pool these pairings anonymously with opted-in guildmates.
- **Quest items, equipped gear and equipment-set items.** Alt+Right-Click → **Allow Sell** overrides any protection.

## The loop

- **Greedy Scavenger** summon with auto-rebuy and dismiss-on-mount.
- **Goblin Merchant** summon when your bags fill, with paced selling so private-server anti-flood doesn't disconnect you. (Both are Project Ebonhold pets; on other realms this step is skipped.)
- **Process Bags** for disenchant, mill, prospect and pick lock: bind a key and hold it to work through a stack. Also home to **Fast Loot** and **auto-open containers**.

## Settings

Everything lives under `/ec`:

| Panel | What it covers |
|---|---|
| **Lists** | Sell, Account Sell, Keep and Delete lists. Add by item ID or name, filter, sort, optional auto-delete on pickup. |
| **List Profiles** | Save, load and rename Sell + Keep list pairs. |
| **Settings Profiles** | Named selling profiles each character uses. Item lists, stats and visual options are not part of them. |
| **Merchant** | Rarity thresholds, bind filters, which vendors to use, Fast and Turbo modes, sell speed, auto-repair (optionally from the guild bank), known recipes. |
| **Keep** | Protections for gear, upgrades, equipment sets, affixes, chance-on-hit items, tomes and recipes, plus the rules for selling duplicate affixes. |
| **Delete** | The Delete List, auto-delete of greys on loot, auto-marking of affix duplicates with no vendor value. All off by default. |
| **Scavenger** | Summon controls, chat and bubble mute, auto-loot threshold. |
| **Process Bags** | Which professions to use, the disenchant rarity cap, soulbound items, the looting toggles. |
| **Import / Export** | Share Sell Lists as text strings. |
| **Item Highlighting** | Bag-slot tints per category with your own colours, item-level overlay, item IDs on tooltips. |
| **Statistics** | Session and lifetime totals, top items and zones. **Stats - Guild** pools opted-in guildmates; **Stats - Server** shows anonymous realm-wide totals (never names). |

Also:

- **Loot Log** (`/ec loot`) lists what you looted and what it is worth, so you can see which drops earn and which are dead weight.
- **Sold History** (`/ec history`) lists everything sold or deleted this session and the rule that decided it.
- **Alt+Right-Click any bag item** to add it to a list, allow-sell it, or trace its decision.
- **Update alerts** when a guild or group member has a newer version.
- **Key bindings** for settings, force-sell, the Loot Log, Process Next and Target Goblin Merchant (works in combat).
- **Minimap button:** left for options, middle for Process Bags, right to turn the addon on or off.
- **Help / FAQ** panel with search.

Every feature in detail: [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md).

## Slash commands

| Command | What it does |
|---|---|
| `/ec` | Open the settings |
| `/ec status` / `enable` / `disable` | Show or set whether EbonClearance runs on this character |
| `/ec profile list\|save\|load\|delete <name>` | Manage Sell List profiles |
| `/ec sprofile list\|save\|use\|delete <name>` | Manage settings profiles (a deleted profile's users go back to Default) |
| `/ec clean` | Report items that are on more than one list; `/ec clean apply` fixes them (Keep > Delete > Sell) |
| `/ec clean upgrades` | Report stale "Keep (upgrade)" entries; add `apply` to remove them |
| `/ec sellinfo [bag slot]` | Why an item will or won't sell (also Alt+Shift+Right-Click) |
| `/ec rules` | Every active rule in plain English, in the order they apply |
| `/ec loot` | Open the Loot Log |
| `/ec history` | Open the Sold History (this session; clears on `/reload`) |
| `/ec minimap on\|off\|reset` | Show, hide or re-centre the minimap button |
| `/ec locale [auto\|frFR\|deDE]` | Show or force the display language; `/reload` to apply fully |
| `/ec bugreport` | Build a diagnostic report to paste into a bug report |
| `/ec perf` / `spike` | Memory, CPU and frame-hitch figures |
| `/ec help` | List every command in chat |

<details>
<summary>Diagnostic commands (for bug reports)</summary>

| Command | What it does |
|---|---|
| `/ecdebug` | Debug info and a bag scan |
| `/ec affixdebug on\|off\|status\|dump\|clear` | Record affix-detection events; `dump` opens them in a copyable window |
| `/ec affixdump` | Your known affixes plus the affixes found on bag items |
| `/ec affixfind <text>` | Search your known affixes for some text |
| `/ec affixfallback on\|off\|status` | Ignore Project Ebonhold's affix data and read the spellbook only; also previews the layout on other realms (`/reload` after) |
| `/ec procdump` | Learned-proc counts and bag items with chance-on-hit lines |
| `/ec captureproc` | Dump chance-on-hit lines, extracted-affix tooltips and the learned-affix catalogue |
| `/ec pairaudit` | Check the recorded chance-on-hit item IDs against the client's item data |
| `/ec paircheck [itemID]` | Read a weapon's proc line and suggest its likely affix (display only) |
| `/ec autolearnsim <itemID> <spellID>` | Simulate an Anvil extraction (item must be in your bags) |
| `/ec autolearnpeek` | Show the chance-on-hit autolearn state |
| `/ec processdebug` | Every Process Bags check, in a copyable window |
| `/ec scandebug <bag> <slot>` | The hidden tooltip lines read for one bag slot |
| `/ec bubbles` | What the Scavenger bubble mute matched |
| `/ec commtest` / `guildtest` | Check addon messages and preview Stats - Guild (works solo) |
| `/ec realmtest` / `servertest` | Check the realm channel and preview Stats - Server (works solo) |
| `/ec procsharetest` | Push three test pairings through the guild-share merge |

</details>

## Other 3.3.5a servers

EbonClearance was written for Project Ebonhold, but runs on a plain WotLK realm. It checks for the affix system when it loads and hides the settings that depend on it.

**Works as usual:** auto-selling greys, the rarity rules, all lists and profiles, import / export, the vendor cycle with Turbo mode, auto-repair, Process Bags, auto-open containers, Fast Loot, bag tints and the item-level overlay, tooltips, the Loot Log, Sold History, Statistics, guild and realm sharing, the Quickstart and translations.

**Hidden, because there is nothing for them to act on:** affix protection and its controls, chance-on-hit protection and sharing, the affix bag tints, the merchant-target choice (every vendor is used), the Scavenger panel and the affix diagnostics. Chance-on-hit protection is switched off, not just hidden: without extraction it could never release a weapon.

Affix knowledge is read from your spellbook, so on Project Ebonhold it works even without the PE addon loaded. One caveat: some 3.3.5a cores lack `IsSpellKnown`, and there Process Bags finds no professions (Convert mode still works).

## Contributing

Fixes and features are welcome as pull requests. AI coding tools: read [AGENTS.md](AGENTS.md) first.

- [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md): read this first. 3.3.5a client gotchas, architecture, naming, UI patterns.
- [docs/TRANSLATING.md](docs/TRANSLATING.md): translating the addon. French and German ship mostly complete.
- [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md): known follow-up cleanups.

Before opening a PR, run the tests with Lua 5.1 and the linters:

```
lua5.1 tests/run_all.lua
luacheck *.lua
stylua --check *.lua
```

## Thanks

Ideas and bug reports from the Project Ebonhold community shape the addon. Some of them:

- **Auto-delete on pickup**: suggested by Sanavesa.
- **Auto-mark PvP gear (Resilience) for deletion**: requested by Murlocked.
- **Class-aware Keep upgrades** (no more bows on Druids or relics on Mages): reported by Murlocked.
- **Auto-mark unsellable affix duplicates for deletion**: requested by Broyo.
- **Chat announcement of auto-deletes**: requested by ayres.
- **Correct comparisons against an equipped two-hander**: reported by "Perfect Bidoof" and Zukii.
- **A hard item-level ceiling on affix selling**: from a near item-loss report by Bizzaro.
- **Quickstart and Stats - Guild fixes**: reported by Qvintus.

## Licence

EbonClearance is source-available under its own licence. You may use it, pass on untouched copies (addon packs included) and change your own copy for your own use. You may not share a changed copy, publish a fork or reuse its code in another addon; send fixes and features as pull requests instead. The author credit, the in-game byline, the provenance globals and the `LICENSE` file must stay intact. Releases up to v2.76.0 stay under the earlier attribution licence. The [LICENSE](LICENSE) file has the full terms.

Release notes are in [CHANGELOG.md](CHANGELOG.md). [NOTICE.md](NOTICE.md) covers prior art: which patterns were adopted from the 3.3.5a addon scene and which are this project's own.
