# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?label=Download&style=for-the-badge)](https://github.com/powerfulqa/EbonClearance/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/powerfulqa/EbonClearance/total?style=for-the-badge&label=Downloads)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/github/license/powerfulqa/EbonClearance?style=for-the-badge)](LICENSE)

A World of Warcraft addon built for **Project Ebonhold**, designed to take the faff out of inventory management. It handles auto-vendoring, item deletion and Greedy Scavenger pet control so you can spend less time sorting bags and more time playing.

## What It Does

**Whitelist-based auto-vendoring** - When you open a vendor (specifically the Goblin Merchant), EbonClearance will automatically sell items that aren't on your whitelist. Rather than telling it what to sell, you tell it what to keep. Everything else goes.

**Item deletion** - For items that can't be sold, the addon can automatically destroy them. You manage a separate delete list of item IDs to control exactly what gets removed.

**Greedy Scavenger management** - If you've used Project Ebonhold's Greedy Scavenger pet, you'll know it loves to talk. EbonClearance can mute its chat messages and speech bubbles, and optionally auto-summon it when you log in.

**Auto-repair** - Gear repairs are handled automatically whenever you visit a vendor, with the cost tracked over time.

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

- Toggle auto-vendoring, deletion, repairs and Greedy Scavenger features on or off
- Manage your whitelist and delete list
- Set a minimum quality threshold for the whitelist (so anything above a certain rarity is kept automatically)
- View lifetime and session statistics
- Control which characters the addon is active on
- Adjust the vendor sell speed and summon delay
- Toggle the minimap button on or off

There's also `/ecdebug` if you need to poke around under the bonnet.

## Requirements

- World of Warcraft (WotLK client, Interface 30300)
- Project Ebonhold server

## Licence

This project is licensed under the MIT Licence. See the [LICENSE](LICENSE) file for details.
