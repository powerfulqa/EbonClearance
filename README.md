# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?label=Download&style=for-the-badge)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads](https://img.shields.io/github/downloads/powerfulqa/EbonClearance/total?style=for-the-badge&label=Downloads&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/github/license/powerfulqa/EbonClearance?style=for-the-badge&cacheSeconds=3600)](LICENSE)

A World of Warcraft addon built for **Project Ebonhold**, designed to take the faff out of inventory management. It handles auto-vendoring, item deletion and Greedy Scavenger pet control so you can spend less time sorting bags and more time playing.

## What It Does

**Whitelist-based auto-vendoring** - Add items to your whitelist by their item ID and they will be automatically sold when you visit a merchant. You can also set a quality threshold to bulk-sell everything at or below a chosen rarity (up to Blue/Rare). Works with the Goblin Merchant, normal vendors, or both. Items with no vendor value are automatically skipped. Your equipped gear is safe, and every item is double-checked against its bag slot before anything gets sold.

**Scan bags to whitelist** - Quickly bulk-add items from your bags by quality. Three colour-coded buttons (White, Green, Blue) on the Whitelist panel scan your bags and add all matching items. Only items with a vendor value are added.

**Blacklist (do not sell)** - Protect valuable items from being sold. If an item is on your blacklist, it will never be vendored regardless of the whitelist or quality threshold. Useful for auction house items like Traveler's Bags that you don't want accidentally sold.

**Auto-sell grey junk** - All grey (Poor quality) items are sold automatically at any merchant, regardless of your whitelist or merchant mode settings. No setup needed.

**Profiles** - Save and load different whitelists and blacklists as named profiles. Handy for swapping between farming spots or activities without keeping one massive list. Each profile stores both your sell list and your protected items. Manage profiles through the settings panel or with slash commands.

**Item deletion** - For items that can't be sold, the addon can automatically destroy them. You manage a separate delete list of item IDs to control exactly what gets removed.

**Greedy Scavenger management** - EbonClearance can mute the Scavenger's chat messages and speech bubbles, auto-summon it when you log in, dismiss it when you mount up, and re-summon it if it despawns or gets stuck on terrain. If you manually unsummon the Scavenger, the addon respects that and won't re-summon it. Other companions (bank mule, mailbox) are never replaced.

**Auto-loot cycle** - When enabled, the addon watches your free bag slots while the Greedy Scavenger is looting. When bags hit your threshold it dismisses the pet, summons the Goblin Merchant and notifies you. Just right-click to sell, and the Scavenger is re-summoned to carry on looting. If you have more than 80 items to sell, selling continues in batches automatically. Configurable bag threshold in Scavenger Settings.

**Auto-repair** - Your gear gets repaired automatically whenever you visit a vendor, and the cost is tracked over time.

**Keep bags open** - Optionally prevents the game from closing your bag windows when you leave a merchant or the Goblin Merchant despawns.

**Session and lifetime statistics** - Keeps a running tally of gold earned, items sold, items deleted, repair costs and average inventory value. All viewable through the config panel.

## Coming from EbonholdStuff?

EbonClearance started life as a fork of [EbonholdStuff](https://github.com/Badutski2/EbonholdStuff) by [Badutski2](https://github.com/Badutski2). The biggest change is the selling philosophy - EbonholdStuff sells everything and you blacklist what to keep, whereas EbonClearance only sells items you've explicitly whitelisted. Nothing gets sold unless you've told it to.

| Feature | EbonholdStuff | EbonClearance |
|---------|:---:|:---:|
| **Selling approach** | Blacklist (sells everything, you protect items) | Whitelist (only sells what you list) |
| **Grey junk auto-sell** | Yes | Yes |
| **Quality filtering** | Fixed (protects green and above) | Configurable threshold (White, Green or Blue) |
| **Blacklist (do not sell)** | No | Yes - protect items from being sold |
| **Scan bags to whitelist** | No | Yes - bulk add by quality (White/Green/Blue) |
| **Whitelist/Blacklist profiles** | No | Yes - save, load, clear and rename profiles |
| **Import/Export lists** | No | Yes - shareable text strings |
| **Default profile safety** | N/A | Default profile locked to empty for new characters |
| **Equipped item protection** | No | Yes - gear is never touched, bag slots verified |
| **Item deletion** | Yes | Yes |
| **Greedy Scavenger management** | Yes | Yes |
| **Auto-loot cycle** | Yes - full summon/dismiss/sell loop | Yes - bag monitoring and Goblin Merchant summon (right-click to sell) |
| **Mount detection** | No | Yes - auto-dismiss on mount, re-summon on dismount |
| **Pet stuck detection** | No | Yes - re-summons if it despawns or wanders |
| **Sell cap (disconnect protection)** | Yes (80/pulse) | Yes (80/run) |
| **Auto-repair** | Yes | Yes |
| **Auto-inviting system** | Yes | Removed |
| **Minimap button** | No | Yes - includes free bag slot count |
| **Keep bags open** | No | Yes |
| **Session/lifetime stats** | Yes | Yes |
| **Character restrictions** | Yes | Yes |

**Removed from EbonholdStuff:** The auto-inviting system (keyword whispers, raid conversion, loot rules) was dropped to keep the addon focused on inventory management.

**If you're switching over:** Your old blacklist won't carry across. You'll need to build up a whitelist of items you actually want to sell. This is a bit more setup upfront but means the addon can never sell something you didn't expect.

## Installation

1. Head to the [latest release](https://github.com/powerfulqa/EbonClearance/releases/latest) and download the zip file
2. Extract the `EbonClearance` folder into your `Interface/AddOns` directory
3. Log in and type `/ec` to open the configuration panel
4. Add items to your whitelist (the things you want to sell) by shift-clicking them or entering their item IDs
5. Optionally set up a delete list for unsellable items you want automatically destroyed

The addon is character-aware, so you can restrict it to specific characters if you'd rather not have it running on every alt.

## Configuration

All settings live under `/ec`, which opens a scrollable config panel. From there you can:

- Manage your whitelist (items to sell) and blacklist (items to protect)
- Scan bags to bulk-add items to the whitelist by quality (White, Green, Blue)
- Save and load profiles with different whitelist and blacklist combinations
- Set a quality threshold to bulk-sell everything up to a chosen rarity
- Choose which merchants the addon works with (Goblin Merchant, normal vendors, or both)
- Toggle auto-vendoring, deletion, repairs and Greedy Scavenger features on or off
- Keep bags open when leaving a merchant
- Import and export whitelists as shareable strings
- View lifetime and session statistics
- Control which characters the addon is active on
- Adjust the vendor sell speed and summon delay
- Right-click the minimap button to quickly enable or disable the addon

## Slash Commands

| Command | Description |
|---------|-------------|
| `/ec` | Open the settings panel |
| `/ec profile list` | Show all saved whitelist profiles |
| `/ec profile save <name>` | Save the current whitelist as a named profile |
| `/ec profile load <name>` | Load a saved profile into the active whitelist |
| `/ec profile delete <name>` | Delete a saved profile |
| `/ec bugreport` | Generate a diagnostic report you can copy and paste into a bug report |
| `/ecdebug` | Show debug info and run a bag scan |

## Requirements

- World of Warcraft (WotLK client, Interface 30300)
- Project Ebonhold server

## For Contributors

Working on the addon? There's developer documentation under [docs/](docs/):

- [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is the prescriptive guide for coding in this addon. Read it first: it covers 3.3.5a client gotchas, the file's architecture, naming conventions, the state machine, UI patterns and the decision not to embed Ace3.
- [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md) is a short list of known follow-up cleanups that weren't part of the last pass.

A Luacheck config ([.luacheckrc](.luacheckrc)) and a StyLua formatter config ([stylua.toml](stylua.toml)) are checked in. Run `stylua --check EbonClearance.lua` and `luacheck EbonClearance.lua` before opening a PR.

## Changelog

### v2.0.12

- **Fix: Can't paste into the Import field** - The Import/Export panel's paste box had no clickable area when empty, so pasting an exported string was impossible unless you typed a character first. Both the export and import boxes now have an explicit height.
- **Fix: Import error text overlapping the grey explanation** - Clicking Import with an empty box showed a red "empty string" warning that overlapped the grey help text below it. The help text is now anchored beneath the status line and flows correctly even when the error wraps to two lines.
- **Fix: Misleading Scavenger Settings description** - The auto-loot cycle note claimed the Goblin Merchant was "targeted for you" when the bag threshold triggers. The addon does not target anything; it only dismisses the Scavenger and summons the Goblin Merchant. The text now describes what actually happens.
- **Fix: Blacklist "Protected Items" label overlap** - On the Blacklist (Do Not Sell) panel, the "Protected Items" title was sitting too close to the line above it, causing a slight overlap when the description wrapped. Hints are now anchored relative to the description so the layout stays clean regardless of text wrapping.
- **Internal cleanup** - State transitions now use named constants instead of string literals so typos fail loudly rather than silently. Hot WoW API calls are cached as local upvalues. The main options panel's build step is factored out of its OnShow. The two Import button handlers were deduplicated into a single helper. A new `PrintNicef` helper replaces most `PrintNice(string.format(...))` call sites. No behavioural changes.

### v2.0.11

- **Fix: Disconnect when selling many items** - The vendor interval minimum was 0.005s which allowed packet flooding at high speeds. Raised minimum to 0.05s and default to 0.1s. Existing settings below the new floor are auto-corrected on load. Slider range updated to 0.05s-0.50s.

### v2.0.10

- **Blacklist (do not sell)** - New panel to protect specific items from ever being sold, overriding the whitelist and quality threshold. Useful for auction house items like Traveler's Bags. Blacklists are saved and loaded with profiles.
- **Scan bags to whitelist** - Three colour-coded buttons (White, Green, Blue) on the Whitelist panel to bulk-add items from your bags by quality. Items with no vendor value are automatically skipped.
- **Distance-based stuck detection** - The Scavenger is now re-summoned if it gets stuck more than 5 yards from the player, not just when it fully despawns.
- **Recursive batch selling** - When selling more than 80 items, the addon now automatically continues in batches until everything is sold, with a single summary at the end.
- **8-second merchant reminder** - If the Goblin Merchant is summoned but you haven't opened the vendor window within 8 seconds, a reminder is printed.
- **Unsellable item protection** - Items with no vendor value (quest items, etc.) are now blocked from the sell queue and from the scan-bags buttons. This fixes an infinite loop where unsellable whitelist items caused batch selling to repeat forever.
- **Batch selling delay** - Re-scan now waits 1 second between batches so the server has time to process sold items.
- **Code cleanup** - Removed 4 dead functions, renamed all legacy EHS_ prefixes to EC_ for consistency.
- **Menu reordering** - Settings panels reordered: Character, Scavenger, Merchant, Profiles, Import/Export, Deletion List, Blacklist - Keep, Whitelist - Sell.
- **Profile counts** - Profiles now show whitelist and blacklist item counts separately.

### v2.0.9

- **Fix: Auto-loot cycle not summoning Goblin Merchant** - The cycle would detect full bags but fail to summon the merchant. Fixed by using `DismissCompanion("CRITTER")` instead of `CallCompanion` for dismissing pets, matching the established 3.3.5a CRITTER-companion dismiss pattern.
- **Fix: Auto-loot cycle only running once** - After selling, the cycle state got stuck at "selling" and never restarted. State transitions are now properly reset in both `FinishRun` and `MERCHANT_CLOSED`.
- **Fix: Mount cancelled by Scavenger re-summon** - When mounting, the stuck detection would re-summon the Scavenger mid-cast, cancelling the mount. A 10-second cooldown now prevents re-summon after a mount dismiss. Also fixed a race condition where a delayed summon from dismounting could fire after remounting.
- **Fix: Manual unsummon respected** - If the user manually unsummons the Scavenger, the addon no longer re-summons it. Only re-summons when the addon itself caused the dismiss (mount, cycle, etc).
- **Fix: Pet summoning when addon is disabled** - All pet automation (stuck detection, mount detection, auto-loot cycle) now respects the addon enabled state.
- **Fix: Scavenger replacing other companions** - The stuck detection no longer re-summons the Scavenger when another companion is active (bank mule, mailbox, etc).
- **Fix: Forward-reference errors** - Moved `EC_GetFreeBagSlots` and Goblin Merchant summon timers to avoid nil function errors at runtime.
- **Goblin Merchant matching** - Now matches by spell ID (600126) as well as name, for more reliable summoning.

### v2.0.8

- **Fix: Pet summoning when addon is disabled** - The Greedy Scavenger would auto-summon (and replace the Goblin Merchant) even when the addon was disabled via the minimap button. All pet automation now respects the enabled state.
- **Fix: Scavenger replacing other companions** - The stuck detection would re-summon the Greedy Scavenger when the user had a different companion active (bank mule, mailbox, etc). It now only re-summons if no companion is out at all.

### v2.0.7

- **Auto-loot cycle** - New opt-in feature in Scavenger Settings. Continuously loops: loot with the Greedy Scavenger, sell when bags are full, then loot again. When your free bag slots hit the threshold, the pet is dismissed and the Goblin Merchant is summoned. Just right-click the merchant to sell and the cycle continues. Enabling the cycle automatically turns on pet summoning, and turning off summoning disables the cycle.
- **Slider format fix** - The bag threshold slider now shows whole numbers instead of seconds.
- **Scavenger Settings layout** - Fixed the description text overlapping the summon checkbox. Added a grey hint explaining that right-clicking the merchant is the only player input needed.
- **Bug report command** - `/ec bugreport` opens a window with a full diagnostic snapshot of your settings, profiles, stats and bag space. Copy and paste it into a GitHub issue.

### v2.0.6

- **Mount detection** - Greedy Scavenger is automatically dismissed when you mount up and re-summoned when you dismount.
- **Bag slot indicator** - The minimap button tooltip now shows your free bag slots, colour-coded green, yellow or red.
- **Pet stuck detection** - If the Greedy Scavenger despawns or gets stuck, it's automatically re-summoned every 5 seconds.
- **Sell cap** - Vendoring is now capped at 80 items per merchant visit to prevent client disconnects. Any leftover items are picked up on the next visit.
- **Duplicate function cleanup** - Removed a duplicate pet summon function that was left over from earlier development.

### v2.0.5

- **Most Sold Item display fixed** - Removed the item ID from the stats display so it just shows the item name and count, avoiding confusion with quantities.
- **Stat accuracy improved** - Sell and delete counts now only increment after the action succeeds, not before. Delete counts only tick up if the item was actually picked up and destroyed.
- **Buyback note** - Added a note to the stats panel that counts don't account for items bought back from a merchant.
- **Version header from TOC** - The settings panel header now pulls the version from the TOC file instead of being hardcoded.
- **Duplicate grey junk text trimmed** - The "grey items are always sold" message was repeated three times on the Whitelist Settings page. Now it's mentioned once at the top.
- **Debug typo fixed** - Removed a stray bracket from the bag scan debug output.

### v2.0.4

- **Search Clear button removed** - The Clear button next to the search filter in Whitelist Settings has been removed to avoid confusion with the profile Clear button. To clear a whitelist, use the Clear button on the Profiles panel instead.
- **Profiles panel description** - Added a reminder that the Default profile is always empty, so users know to pick a name before saving.
- **UI fixes** - Fixed the Profiles panel description overlapping the active profile label. Added EbonholdStuff comparison table and humanised the README.

### v2.0.3

- **Equipped item protection** - Every item is now checked before being sold or deleted, so your equipped gear can never be touched. Bag slots are also verified in case items shift around mid-vendoring.
- **Default profile locked to empty** - The Default profile is always empty and can't be saved to, deleted or renamed. New characters start fresh instead of picking up another character's whitelist.
- **Clear button on profiles** - Each profile in the Saved Profiles list now has a Clear button to empty it out without deleting it.
- **Quality dropdown capped at Blue** - The sell-by-quality threshold tops out at Blue (Rare) now. Epic has been removed. If you had it set to Epic, it's been bumped down to Blue automatically.
- **UI overlap fixes** - Sorted the "Allowed Characters" label overlapping the checkbox in Character Settings, and the "List name" sitting on top of the description in Import/Export.

### v2.0.2

- Fixed misleading whitelist description across UI and README.

### v2.0.0

- First release. Whitelist-based auto-vendoring, item deletion, Greedy Scavenger management, whitelist profiles, import/export, auto-repair and session stats.

## Licence

This project is licensed under the MIT Licence. See the [LICENSE](LICENSE) file for details.
