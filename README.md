# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?label=Download&style=for-the-badge)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads](https://img.shields.io/github/downloads/powerfulqa/EbonClearance/total?style=for-the-badge&label=Downloads&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/github/license/powerfulqa/EbonClearance?style=for-the-badge)](LICENSE)

A World of Warcraft addon built for **Project Ebonhold**, designed to take the faff out of inventory management. It handles auto-vendoring, item deletion and Greedy Scavenger pet control so you can spend less time sorting bags and more time playing.

## What It Does

**Whitelist-based auto-vendoring** - When you open a vendor, EbonClearance will automatically sell items that aren't on your whitelist. Rather than telling it what to sell, you tell it what to keep. Everything else goes. You can choose whether this runs at the Goblin Merchant only, normal merchants only, or both.

**Auto-sell grey junk** - All grey (Poor quality) items are sold automatically at any merchant, regardless of your whitelist or merchant mode settings. No setup needed.

**Whitelist profiles** - Save and load different whitelists as named profiles. Handy for swapping between farming locations or activities without maintaining one massive list. Manage profiles through the settings panel or with `/ec profile save|load|delete|list`.

**Item deletion** - For items that can't be sold, the addon can automatically destroy them. You manage a separate delete list of item IDs to control exactly what gets removed.

**Greedy Scavenger management** - If you've used Project Ebonhold's Greedy Scavenger pet, you'll know it loves to talk. EbonClearance can mute its chat messages and speech bubbles, and optionally auto-summon it when you log in.

**Auto-repair** - Gear repairs are handled automatically whenever you visit a vendor, with the cost tracked over time.

**Keep bags open** - Optionally prevents the game from closing your bag windows when you leave a merchant or the Goblin Merchant despawns.

**Session and lifetime statistics** - Keeps a running tally of gold earned, items sold, items deleted, repair costs and average inventory value. All viewable through the config panel.

## Installation

1. Head to the [latest release](https://github.com/powerfulqa/EbonClearance/releases/latest) and download the zip file
2. Extract the `EbonClearance` folder into your `Interface/AddOns` directory
2. Log in and type `/ec` to open the configuration panel
3. Add items to your whitelist (the things you want to keep) by shift-clicking them or entering their item IDs
4. Optionally set up a delete list for unsellable items you want automatically destroyed

The addon is character-aware, so you can restrict it to specific characters if you'd rather not have it running on every alt.

## Configuration

All settings are accessible through `/ec`, which opens a scrollable config panel. From there you can:

- Choose which merchants the addon works with (Goblin Merchant, normal vendors, or both)
- Toggle auto-vendoring, deletion, repairs and Greedy Scavenger features on or off
- Manage your whitelist and delete list
- Save and load whitelist profiles for different situations
- Set a minimum quality threshold for the whitelist (so anything above a certain rarity is kept automatically)
- Keep bags open when leaving a merchant
- View lifetime and session statistics
- Control which characters the addon is active on
- Adjust the vendor sell speed and summon delay
- Right-click the minimap button to quickly enable or disable the addon

There's also `/ecdebug` if you need to poke around under the bonnet.

## Requirements

- World of Warcraft (WotLK client, Interface 30300)
- Project Ebonhold server

## Licence

This project is licensed under the MIT Licence. See the [LICENSE](LICENSE) file for details.
