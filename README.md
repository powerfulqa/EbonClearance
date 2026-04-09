# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?label=Download&style=for-the-badge)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads](https://img.shields.io/github/downloads/powerfulqa/EbonClearance/total?style=for-the-badge&label=Downloads&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/github/license/powerfulqa/EbonClearance?style=for-the-badge)](LICENSE)

A World of Warcraft addon built for **Project Ebonhold**, designed to take the faff out of inventory management. It handles auto-vendoring, item deletion and Greedy Scavenger pet control so you can spend less time sorting bags and more time playing.

## What It Does

**Whitelist-based auto-vendoring** - Add items to your whitelist by their item ID and they'll be automatically sold when you visit a merchant. You can also set a quality threshold to bulk-sell everything at or below a chosen rarity (up to Blue/Rare). Works with the Goblin Merchant, normal vendors, or both. The addon only ever touches loose bag items - your equipped gear is safe, and every item is double-checked against its bag slot before anything gets sold.

**Auto-sell grey junk** - All grey (Poor quality) items are sold automatically at any merchant, regardless of your whitelist or merchant mode settings. No setup needed.

**Whitelist profiles** - Save and load different whitelists as named profiles. Handy for swapping between farming spots or activities without keeping one massive list. Each profile has a Clear button if you want to empty it out, and the Default profile is always locked to empty so new characters start fresh. Manage profiles through the settings panel or with slash commands.

**Item deletion** - For items that can't be sold, the addon can automatically destroy them. You manage a separate delete list of item IDs to control exactly what gets removed.

**Greedy Scavenger management** - If you've used Project Ebonhold's Greedy Scavenger pet, you'll know it loves to talk. EbonClearance can mute its chat messages and speech bubbles, auto-summon it when you log in, dismiss it when you mount up, and re-summon it if it despawns or gets stuck.

**Auto-loot cycle** - When enabled, the addon watches your free bag slots while the Greedy Scavenger is looting. When bags are nearly full it dismisses the pet, summons the Goblin Merchant and auto-targets it for you. Just right-click to sell, and the Scavenger is re-summoned to carry on looting. Configurable bag threshold in Scavenger Settings.

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
| **Whitelist/Blacklist profiles** | No | Yes - save, load, clear and rename profiles |
| **Import/Export lists** | No | Yes - shareable text strings |
| **Default profile safety** | N/A | Default profile locked to empty for new characters |
| **Equipped item protection** | No | Yes - gear is never touched, bag slots verified |
| **Item deletion** | Yes | Yes |
| **Greedy Scavenger management** | Yes | Yes |
| **Auto-loot cycle** | Yes - full summon/dismiss/sell loop | Yes - bag monitoring, merchant summon and auto-target |
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

- Choose which merchants the addon works with (Goblin Merchant, normal vendors, or both)
- Toggle auto-vendoring, deletion, repairs and Greedy Scavenger features on or off
- Manage your whitelist and delete list
- Save and load whitelist profiles for different situations
- Set a quality threshold for the whitelist (White, Green or Blue - anything above your chosen rarity is kept)
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

## Changelog

### v2.0.9

- **Fix: Auto-loot cycle not summoning Goblin Merchant** - The cycle would detect full bags but fail to summon the merchant. Fixed by using `DismissCompanion("CRITTER")` instead of `CallCompanion` for dismissing pets, matching the approach used by EbonholdAutoLoot.
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
