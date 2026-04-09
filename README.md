# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?label=Download&style=for-the-badge)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads](https://img.shields.io/github/downloads/powerfulqa/EbonClearance/total?style=for-the-badge&label=Downloads&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/github/license/powerfulqa/EbonClearance?style=for-the-badge)](LICENSE)

A World of Warcraft addon built for **Project Ebonhold**, designed to take the faff out of inventory management. It handles auto-vendoring, item deletion and Greedy Scavenger pet control so you can spend less time sorting bags and more time playing.

## What It Does

**Whitelist-based auto-vendoring** - Add items to your whitelist by their item ID and they will be automatically sold when you visit a merchant. You can also enable a quality threshold to bulk-sell everything at or below a chosen rarity (up to Blue/Rare). You choose whether this runs at the Goblin Merchant only, normal merchants only, or both. The addon includes safety checks to ensure only loose bag items are ever sold — equipped gear is always protected, and each item is verified before being vendored.

**Auto-sell grey junk** - All grey (Poor quality) items are sold automatically at any merchant, regardless of your whitelist or merchant mode settings. No setup needed.

**Whitelist profiles** - Save and load different whitelists as named profiles. Handy for swapping between farming locations or activities without maintaining one massive list. You can clear a profile's contents from the profile list, and the Default profile is always locked to empty so new characters start with a clean slate. Manage profiles through the settings panel or with slash commands.

**Item deletion** - For items that can't be sold, the addon can automatically destroy them. You manage a separate delete list of item IDs to control exactly what gets removed.

**Greedy Scavenger management** - If you've used Project Ebonhold's Greedy Scavenger pet, you'll know it loves to talk. EbonClearance can mute its chat messages and speech bubbles, and optionally auto-summon it when you log in.

**Auto-repair** - Gear repairs are handled automatically whenever you visit a vendor, with the cost tracked over time.

**Keep bags open** - Optionally prevents the game from closing your bag windows when you leave a merchant or the Goblin Merchant despawns.

**Session and lifetime statistics** - Keeps a running tally of gold earned, items sold, items deleted, repair costs and average inventory value. All viewable through the config panel.

## Installation

1. Head to the [latest release](https://github.com/powerfulqa/EbonClearance/releases/latest) and download the zip file
2. Extract the `EbonClearance` folder into your `Interface/AddOns` directory
3. Log in and type `/ec` to open the configuration panel
4. Add items to your whitelist (the things you want to sell) by shift-clicking them or entering their item IDs
5. Optionally set up a delete list for unsellable items you want automatically destroyed

The addon is character-aware, so you can restrict it to specific characters if you'd rather not have it running on every alt.

## Configuration

All settings are accessible through `/ec`, which opens a scrollable config panel. From there you can:

- Choose which merchants the addon works with (Goblin Merchant, normal vendors, or both)
- Toggle auto-vendoring, deletion, repairs and Greedy Scavenger features on or off
- Manage your whitelist and delete list
- Save and load whitelist profiles for different situations
- Set a minimum quality threshold for the whitelist (White, Green or Blue — so anything above your chosen rarity is kept automatically)
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
| `/ecdebug` | Show debug info and run a bag scan |

## Requirements

- World of Warcraft (WotLK client, Interface 30300)
- Project Ebonhold server

## Changelog

### v2.0.3

- **Safety: equipped item protection** — The addon now verifies each item before selling or deleting, preventing any chance of equipped gear being touched. Items are also checked against their original slot to guard against bag contents shifting mid-vendoring.
- **Default profile locked to empty** — The Default whitelist profile is always empty and cannot be saved to, deleted or renamed. New characters start with a clean slate instead of inheriting another character's whitelist.
- **Clear button on profiles** — Each profile row in the Saved Profiles list now has a Clear button to wipe its contents without deleting the profile.
- **Quality dropdown capped at Blue** — The sell-by-quality threshold no longer offers Epic (Purple) as an option. Existing settings above Blue are automatically capped.
- **UI overlap fixes** — Fixed the "Allowed Characters" label overlapping the checkbox in Character Settings, and the "List name" overlapping the description in the Import/Export panel.

### v2.0.2

- Fixed misleading whitelist description across UI and README.

### v2.0.0

- Initial release with whitelist-based auto-vendoring, item deletion, Greedy Scavenger management, whitelist profiles, import/export, auto-repair and session statistics.

## Licence

This project is licensed under the MIT Licence. See the [LICENSE](LICENSE) file for details.
