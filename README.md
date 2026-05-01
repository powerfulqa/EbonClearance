# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?label=Download&style=for-the-badge&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/powerfulqa/EbonClearance/badge-data/downloads.json&style=for-the-badge&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)

A World of Warcraft addon built for **Project Ebonhold**, designed to take the faff out of inventory management. It handles auto-vendoring, item deletion and Greedy Scavenger pet control so you can spend less time sorting bags and more time playing.

## What It Does

**Whitelist-based auto-vendoring** - Add items to your whitelist by their item ID and they will be automatically sold when you visit a merchant. You can also set per-rarity quality thresholds (under Merchant Settings) with an optional max item level for each rarity, so you can say "sell all whites and greens below iLvl 150 but never sell blues or epics" or "sell every equippable item under iLvl 170 regardless of colour, including purples". Four tiers: White (Common), Green (Uncommon), Blue (Rare), Purple (Epic). Works with the Goblin Merchant, normal vendors, or both. Items with no vendor value are automatically skipped. Your equipped gear is safe, and every item is double-checked against its bag slot before anything gets sold.

**Character and account whitelists** - Keep a per-character whitelist for things only that character sells, plus an account-wide whitelist for shared trash (reagents, seasonal items) that gets sold on every alt. Both lists are consulted when vendoring; either one listing an item is enough.

**Scan bags to whitelist** - Quickly bulk-add items from your bags by quality. Three colour-coded buttons (White, Green, Blue) on each whitelist panel scan your bags and add all matching items. Only items with a vendor value are added. A separate "Add matching in bags" field lets you add every bag item whose name contains a typed substring (handy for seasonal prefixes).

**Blacklist (do not sell)** - Protect valuable items from being sold. If an item is on your blacklist, it will never be vendored regardless of the whitelist or quality threshold. Useful for auction house items like Traveler's Bags that you don't want accidentally sold.

**Auto-sell grey junk** - All grey (Poor quality) items are sold automatically at any merchant, regardless of your whitelist or merchant mode settings. No setup needed.

**Profiles** - Save and load different whitelists and blacklists as named profiles. Handy for swapping between farming spots or activities without keeping one massive list. Each profile stores both your sell list and your protected items. Manage profiles through the settings panel or with slash commands. Destructive actions (clear, delete, reset stats) prompt for confirmation.

**List conflict clean-up** - Adds that would put an item on conflicting lists are refused at input time with a clear message, and the Alt+Right-Click bag menu greys out rows that would conflict. Legacy or imported conflicts can still be reported via `/ec clean` and auto-resolved with `/ec clean apply` (precedence: blacklist > delete-list > whitelist).

**Item deletion** - For items that can't be sold, the addon can automatically destroy them. You manage a separate delete list of item IDs to control exactly what gets removed.

**Auto-open lootable containers** - Optional toggle on the Scavenger Settings panel. When enabled, EbonClearance opens any "Right Click to Open" container in your bags as soon as it lands - gift bags, treasure pouches, freebie pouches, etc. Lockboxes that need a key or lockpick are skipped. Combat-paused.

**Right-click bag-item menu** - Alt+Right-Click any item in your bags to add it to a whitelist (character or account), blacklist, or deletion list, or to sell it immediately. Saves a trip to the settings panel for one-off list edits. A small grey "Alt+Right-Click for EbonClearance menu" hint on bag-item tooltips makes the shortcut discoverable.

**Greedy Scavenger management** - EbonClearance can mute the Scavenger's chat messages and speech bubbles, auto-summon it when you log in, dismiss it when you mount up, and re-summon it if it despawns or gets stuck on terrain. If you manually unsummon the Scavenger, the addon respects that and won't re-summon it. Other companions (bank mule, mailbox) are never replaced.

**Auto-loot cycle** - When enabled, the addon watches your free bag slots while the Greedy Scavenger is looting. When bags hit your threshold it dismisses the pet, summons the Goblin Merchant and notifies you. Just right-click to sell, and the Scavenger is re-summoned to carry on looting. If you have more than 80 items to sell, selling continues in batches automatically. Configurable bag threshold in Scavenger Settings.

**Auto-repair** - Your gear gets repaired automatically whenever you visit a vendor, and the cost is tracked over time.

**Keep bags open** - Optionally prevents the game from closing your bag windows when you leave a merchant or the Goblin Merchant despawns.

**Session and lifetime statistics** - Keeps a running tally of gold earned, items sold, items deleted, repair costs and average inventory value. Session deltas are shown inline next to each lifetime figure so you can see at a glance what the current play session added. Lifetime and session counters reset independently.

**Key bindings** - Bind keys for Open/close settings, Toggle enabled, and Force sell at current merchant under the WoW Key Bindings menu.

## Coming from EbonholdStuff?

EbonClearance started life as a fork of [EbonholdStuff](https://github.com/Badutski2/EbonholdStuff) by [Badutski2](https://github.com/Badutski2). The biggest change is the selling philosophy - EbonholdStuff sells everything and you blacklist what to keep, whereas EbonClearance only sells items you've explicitly whitelisted. Nothing gets sold unless you've told it to.

| Feature | EbonholdStuff | EbonClearance |
|---------|:---:|:---:|
| **Selling approach** | Blacklist (sells everything, you protect items) | Whitelist (only sells what you list) |
| **Grey junk auto-sell** | Yes | Yes |
| **Quality filtering** | Fixed (protects green and above) | Configurable per-rarity threshold (White, Green, Blue, Purple) with optional max iLvl |
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

- Manage your character whitelist, account-wide whitelist, blacklist, and deletion list
- Scan bags to bulk-add items by quality (White, Green, Blue) on either whitelist panel
- Add items matching a name substring in one go via the "Add matching in bags" field on any list panel
- Save and load profiles with different whitelist and blacklist combinations
- Set per-rarity quality thresholds with optional max item levels (e.g. "sell all whites under iLvl 150, all greens under iLvl 170, no blues") on Merchant Settings
- Choose which merchants the addon works with (Goblin Merchant, normal vendors, or both)
- Toggle auto-vendoring, deletion, repairs, Greedy Scavenger, and auto-opening of lootable containers on or off
- Keep bags open when leaving a merchant
- Enable Fast Mode for higher vendoring throughput at slightly higher disconnect risk
- Import and export whitelists as shareable strings (per-section Source / Target list selectors)
- View lifetime and session statistics side-by-side, reset either independently
- Control which characters the addon is active on
- Adjust the vendor sell speed and summon delay
- Right-click the minimap button to quickly enable or disable the addon
- Bind keys for Open/close settings, Toggle enabled, and Force sell at current merchant under the WoW Key Bindings menu
- Alt+Right-Click any bag item for a quick-action menu (whitelist, blacklist, delete, sell now)

## Slash Commands

| Command | Description |
|---------|-------------|
| `/ec` | Open the settings panel |
| `/ec profile list` | Show all saved whitelist profiles |
| `/ec profile save <name>` | Save the current whitelist as a named profile |
| `/ec profile load <name>` | Load a saved profile into the active whitelist |
| `/ec profile delete <name>` | Delete a saved profile |
| `/ec clean` | Report any item IDs present in more than one list |
| `/ec clean apply` | Auto-resolve list conflicts using precedence blacklist > delete-list > whitelist |
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

### v2.8.0

- **New: Purple (Epic) row on the Merchant Settings quality threshold.** The per-rarity quality threshold now offers four rows instead of three (White / Green / Blue / Purple), matching the in-game weapon and armour quality progression. Same `enabled` checkbox plus `max iLvl` numeric input as the other rows. Same strict-mode iLvl filter rule applies (cap > 0 only sells equippable items with a visible iLvl on the tooltip). Default off so existing users keep their current behaviour; opt-in per rarity. The new field lives at `DB.qualityRules[4]`. Useful for selling off lower-tier epics to make room for higher-iLvl drops without hand-whitelisting every item ID.
- **Fix: Scavenger and Goblin Merchant re-summons no longer get silently swallowed by the spell system during heavy combat.** `CallCompanion` goes through WoW's normal cast pipeline, so issuing it while the player is mid-cast, mid-channel, or on the GCD from an instant-cast ability gets rejected by the server without raising any error. Stationary intense farming (mashing buttons at a tap point) was the worst case: every retry tick happened to land inside a cast slot, so the Scavenger could end up dismissed for the rest of a session. v2.8.0 adds a new `EC_IsPlayerBusy()` gate that defers the call until the player is clear of casting, channeling, and movement. Same gate applied to the bag-full Goblin Merchant summon path.
- **Fix: Goblin Merchant retry budget raised from 1 attempt to 3.** The previous one-shot retry was sized for the post-dismiss companion-GCD overlap (lag) case. Under heavy combat the bare GCD from instant-cast rotations can swallow several attempts in a row before one lands; 3 attempts (re-armed through the busy gate, so they only fire during clear windows) covers that without giving up early.
- **Faster retry cadence while waiting to re-summon.** When `EC_addonDismissed = true` (i.e. the addon is actively trying to bring the pet back), the pet-check tick now samples at 1 second instead of 5 seconds. Catches cast-clear windows much faster during heavy combat. Falls back to the 5-second baseline once the pet is back.
- **Fix: post-merchant Scavenger restore now respects the cast-busy gate too.** The auto-loot cycle's "merchant gone, bring the Scavenger back" path goes through `SummonGreedyScavenger`, which is a separate code path from the tick-driven retry. The cast-busy gate was only added to the tick path in the initial v2.7.1 work; under heavy combat the post-merchant restore could still fire `CallCompanion` into a cast slot, get silently rejected, and then unconditionally mark the pet as restored - leaving the Scavenger gone for the rest of the session. The helper now defers via the same gate and marks `EC_addonDismissed = true` so the tick retry picks it up the next time the player has a clear cast/movement window.
- **Fix: leftover Goblin Merchant blocked the Scavenger from coming back.** The Goblin Merchant doesn't auto-dismiss when the merchant window closes - it lingers in the CRITTER slot for some time. The post-merchant Scavenger restore path correctly recognised that the slot was occupied, but its `if anyPetOut then return end` guard was designed to respect the user's manually-summoned third-party companions (bank mule, mailbox) - it didn't distinguish those from our own leftover goblin from the bag-full cycle. Result: the resummon path bailed forever and the Scavenger never came back, no matter how long the player waited. The pet-check now tracks whether the in-slot pet is specifically the goblin (matched by `TARGET_NAME` or `GOBLIN_MERCHANT_SPELL_ID`); if so, it dismisses it and proceeds with the Scavenger summon during the next clear cast/movement window. Genuine user companions still get the respect they had before.
- **Fix: false-positive "Scavenger went quiet during looting" loop.** v2.7.0's loot-silence stuck signal correctly noticed when 2+ loots happened inside 60 s without the Scavenger speaking, but the speech tracker was too strict: it required an exact `author == "Greedy Scavenger"` match plus a `says|yells|whispers` pattern in the message body. On Project Ebonhold the pet's chat author can come through as a customised name (e.g. `Serv's Scavenger`) and emote-style messages don't carry the verb pattern - both bypassed the tracker even though the pet was visibly speaking and looting. Result: every two loots fired the dismiss-and-resummon, looped indefinitely. Speech tracking now accepts any chat line where the author OR the body contains the substring `scavenger` (case-insensitive). As a defensive belt-and-braces, the silence baseline is also refreshed every time the pet transitions back to the summoned state, so a freshly-summoned pet can't be falsely accused of having been silent the whole time.
- **Fix: tooltip annotation now reflects what will actually be sold.** Items on the whitelist that the addon can't actually vendor used to be annotated `Will Sell - Whitelisted` in green - the same wording as a normal whitelisted item - so users would see the green "will sell" line at the bag tooltip and then be surprised when the Goblin Merchant skipped them. Two cases are now called out explicitly in warning-yellow: `Whitelisted - No Vendor Price (cannot sell)` for items with `sellPrice = 0` (common with custom Project Ebonhold drops), and `Whitelisted - Currently Equipped (cannot sell)` when the item is on the whitelist but the player has it equipped. The discrepancy with the merchant cycle is now visible at the point of decision instead of "why didn't this sell?" at the vendor.

### v2.7.0

- **Smarter Scavenger stuck detection** - Adds a second stuck signal alongside the existing 180s movement-time threshold. The addon now tracks Scavenger speech timestamps and player loot events, and the Scavenger is dismissed-and-resummoned if you've looted at least 2 corpses inside 60s without hearing it speak. Catches the kills-and-loots-in-place case (AOE channels, melee in one spot, tight kiting) that movement-time alone misses because the player isn't moving much. Both signals still go through the same flag-based gate, so manual portrait dismisses are honoured exactly as before.
- **Stuck-resummon now talks to you** - The previous code paths dismissed and resummoned the Scavenger silently; you only knew it had happened if you noticed the pet had a different position. EbonClearance now prints which signal fired ("Scavenger fell behind." or "Scavenger went quiet during looting.") and a hint that the actual resummon waits for you to stop moving (because Project Ebonhold's CRITTER summon won't engage follow-AI on a moving player).
- **Cross-list conflict guard at add time** - Adding an item to one list while it sits on a conflicting one is now refused at input time with a clear message. Same-intent scopes (per-character whitelist + account whitelist, both "keep") still work as before; cross-intent (keep vs sell vs delete) is what's refused. Bulk paths (substring match, scan-by-quality) skip conflicting items and report the skipped count alongside the added count. The `/ec clean` post-hoc cleaner is unchanged and remains as a safety net for legacy data and imports.
- **Smart bag-context menu** - Alt+Right-Click on a bag item now greys out list rows that would create a conflict, mirroring how Sell Now disables itself when no merchant is open. The highlighted "Remove from X" row tells you which list currently holds the item, so the disabled rows don't need to repeat it.
- **Fix: PLAYER_LOGIN welcome message routes through `PrintNice`** - The login greeting was the last direct `DEFAULT_CHAT_FRAME:AddMessage` call outside `PrintNice` itself, violating the documented "prefix and colour are owned by `PrintNice`" rule. Drops the redundant "EbonClearance Enabled" text since `PrintNice` already prepends `[EbonClearance]`.

### v2.6.1

- **Fix: Scavenger no longer permanently disables itself after a stationary despawn.** v2.4.0 introduced a heuristic (`EC_ClassifyScavengerTransition`) that watched the Scavenger's out-state and used the player's instantaneous speed as a proxy for "manual portrait dismiss vs. game-leash dismiss" - moving = re-summon, stationary = treat as manual and never re-summon again. The premise was wrong: server-side companion timers, brief disconnects, loading screens, and phasing all cause the pet to despawn while the player happens to be standing still. Each of those latched a permanent "user dismissed" flag that nothing short of an explicit `/ec` re-summon would clear, and a knock-on effect was that the bag-full Goblin Merchant summon could fail with `Goblin Merchant failed to summon. Resuming looting.` The classifier and its companion `EC_userDismissed` flag are now removed entirely. The simpler rule: the addon only auto-resummons the Scavenger if **it** dismissed it (mount cycle or stuck-detection). Manual portrait dismisses, server despawns, and disconnects all leave the pet alone until the user re-summons -- the v2.3.x behaviour, before the broken classifier was added.
- **Fix: stuck-detection threshold raised from 20 s to 180 s of cumulative player movement.** The 20 s value fired roughly every 60-90 s of normal questing, producing visible "the Scavenger just disappeared" glitches even when the pet wasn't actually stuck. 180 s leaves the pet alone through normal kill-loot-move questing cadence and only intervenes when the player has been moving for a sustained period that's almost certainly outpaced the leash.
- **Fix: stuck-detection re-summon defers until the player stops moving, and retries until it lands.** Two related issues on Project Ebonhold's CRITTER summon path: (a) `CallCompanion` issued while the player is moving spawns the Scavenger but its follow AI never engages -- the critter sits where it was summoned as a zombie that never catches up; (b) the previous addon code cleared `EC_addonDismissed` immediately on the call, so a silently-rejected summon left the addon thinking the pet had been restored when it actually hadn't, leaving the Scavenger gone until a mount cycle or `/ec` summon brought it back. The re-summon path now (1) defers `CallCompanion` until the player is stationary, so the spawn lands cleanly and the pet starts following immediately, and (2) clears the dismiss flag only after the next 5 s tick *observes* the pet actually summoned -- a rejected or deferred call simply re-fires on the next tick until one confirms.
- **Fix: one-shot retry on Goblin Merchant summon under lag.** `EC_TickGoblinTarget`'s 2 s post-summon verify now retries `CallCompanion` once if the first attempt is observed to have missed (companion GCD overlap from the preceding dismiss is the usual cause). Previously the verify would give up immediately and reset to looting; now the failure message only fires if both attempts miss.

### v2.6.0

- **Responsive Interface Options layouts** - The Scavenger Settings and Merchant Settings panels are now wrapped in a vertical scroll frame so every widget stays reachable at the default 3.3.5a container width (previously the bottom of those panels was being clipped under the OK/Cancel button strip on narrow setups). The scroll bar hides automatically when content fits, so wider configurations look unchanged.
- **Fix: Whitelist Character and Whitelist Account list overflow** - Both list UIs now auto-fill the remaining panel height (anchored `BOTTOMRIGHT` to the panel) instead of using a fixed 290 px height that could clip the bottom row at narrow widths.
- **Fix: "Add from bags:" buttons overlapping description on Whitelist panels** - The scan-by-quality row is now cascade-anchored to the description's `BOTTOMLEFT`, so it stays below the description regardless of how many lines it wraps to. Same treatment applied to the Merchant Quality Threshold block.
- **Fix: Orphan scroll arrows on short lists** - On the Whitelist, Account Whitelist, Blacklist, Deletion, Character Settings, and Profiles panels, when the list had fewer items than the visible area the scroll-bar arrows were rendering as floating icons at the right edge. A new `OnScrollRangeChanged` hook now hides the scroll bar (arrows + thumb) when content fits.
- **Tightened explanatory text** - The Merchant Quality Threshold description, the auto-loot cycle note on Scavenger Settings, and a couple of redundant cross-cutting lines were shortened so panels read more cleanly at narrow widths. Generic information that isn't context-specific to a sub-panel (such as "grey junk is sold automatically") is consolidated on the Main panel.
- **Profiles row labels shortened** - Saved profile rows now read `(N wl, N bl)` instead of `(N whitelist, N blacklist)`, fitting cleanly when all three Load / Clear / Delete buttons are visible without truncating the profile name.
- **Polish: Summon delay slider format** - The slider now reads `0.0s ... 3.0s` (was `0.000s ... 3.000s`). Three decimals were noise on a 0.1-step slider. Vendoring Speed slider unchanged (its 0.005 step warrants the precision).
- **Copy-detection fingerprint and watermark** - EbonClearance now writes a `__EbonClearance_watermark` global at load (visible to `/run` introspection) and appends a `;fp=<6 hex>` fingerprint suffix to every export string. The fingerprint is back-compat: imports tolerate strings with or without the suffix, and there is no warning on missing or corrupted fingerprints (hand-edited strings keep working). The mechanism's purpose is mechanical detection of verbatim copies in derivative addons. See [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) "Fingerprint and watermark" for the convention.
- **NOTICE.md: prior-art acknowledgement** - New file at the repo root documents which structural patterns in this addon (the source-available licence shape, the `__<addon>_origin` / `__<addon>_author` provenance globals form) are adopted from conventions already present in the 3.3.5a addon ecosystem rather than originated here. Read NOTICE.md before drawing conclusions about influence in either direction.
- **Internal: comment audit on the provenance globals; LICENSE section 2(d) preservation list expanded** to include `__EbonClearance_watermark`. Historical changelog text generalised to remove a stale named cross-reference.

### v2.5.0

- **Per-rarity quality threshold with optional max item level** - The single "Sell items up to quality" dropdown is replaced with three independent per-rarity rows (White, Green, Blue) on the Merchant Settings panel. Each rarity has its own checkbox and an optional max iLvl input. Setting iLvl to `0` means no cap (sells every item of that rarity, including cloth and trade goods); setting it above `0` is a strict filter that only sells **equippable items** at or below the cap - trade goods, reagents, consumables, and anything without "Item Level" on its tooltip are protected. This means setting White cap = 100 won't accidentally vendor Runecloth, even though `GetItemInfo` reports an internal itemLevel of 50 for it. The mental model is "the cap only filters items I can SEE the iLvl of". This makes it possible to say things like "sell all whites and all greens up to iLvl 150 but no blues", or "sell every equippable under iLvl 170 regardless of rarity", without surprises. Default all off; existing users get a one-time migration from the old cumulative dropdown so their previous behaviour is preserved. New saved variable `DB.qualityRules` holds the per-rarity state. The legacy `DB.whitelistMinQuality` / `DB.whitelistQualityEnabled` keys remain for one release in case of rollback.
- **Tooltip annotation shows iLvl-cap state** - Items either show `[EC] Will Sell - Quality Threshold` (green) when they qualify, or one of two `[EC] Protected -` (warning yellow) lines when the cap protects them: above max iLvl, or no iLvl on item with cap active. Makes the cap visible at the point of decision rather than abstract on the settings panel.
- **Whitelist still wins over the cap** - Items on your whitelist sell regardless of any iLvl cap. The cap only acts on the quality-threshold pass.
- **Smart Alt+Right-Click context menu** - Each list row now toggles between "Add to ..." (white) and "Remove from ..." (orange) based on the item's current membership. If the item is already on the Whitelist (Character), the row reads "Remove from Whitelist (Character)" in orange and clicking it removes the item; otherwise it reads "Add to Whitelist (Character)" in white. Each row checks its own list independently, so an item on the Account whitelist + Blacklist shows two orange "Remove from ..." rows and two white "Add to ..." rows.
- **Welcome page text refresh** - The opening description on the main `/ec` panel was stale (predated the account whitelist, blacklist, and Alt+Right-Click menu). Rewritten to mention the per-character/account whitelist split, the blacklist, the per-rarity quality threshold with iLvl caps, and a discoverability tip for the bag context menu.

### v2.4.0

- **Performance/maintainability pass and two Scavenger lifecycle fixes.** The pet stuck-detection no longer relies on the `UnitPosition` distance check (which doesn't exist on stock 3.3.5a and silently no-oped); it now uses a movement-time accumulator that re-summons the Scavenger when it has been out and stationary too long. The manual-dismiss-respect logic now survives a mount/dismount cycle (was previously losing the `EC_addonDismissed` intent across `UNIT_AURA` mount transitions). Plus a code-quality sweep across the file. See the v2.4.0 commit and PR for full details.

### v2.3.0

- **Auto-open lootable containers** - New opt-in toggle on the Scavenger Settings panel. When enabled, EbonClearance reacts to bag changes and automatically opens any container in your bags that shows the standard "Right Click to Open" tooltip line - the gift bags, treasure pouches, and freebie pouches that drop from quests, mailbox, or as world-drop loot. Lockboxes that need a key or lockpick are skipped. Combat-paused. Containers are opened in sequence with a small inter-item delay so the previous open isn't interrupted. New saved variable `DB.autoOpenContainers` defaults to `false`; turn it on under Scavenger Settings → "Auto-open lootable containers from your bags". `/ec bugreport` now includes the toggle state.
- **Right-click bag-item context menu** - Alt+Right-Click any item in your bags to open an EbonClearance popup: Add to Whitelist (Character / Account), Add to Blacklist, Add to Deletion List, or Sell Now (only enabled when a merchant window is open). No more trip to the settings panel for one-off list edits. The default right-click-to-use behaviour is unchanged - only Alt+Right-Click triggers the menu. Closes on Escape or Cancel.
- **Discoverability hints** - A subtle grey "Alt+Right-Click for EbonClearance menu" line is appended to every bag-item tooltip, and a yellow "Tip:" line at the bottom of Scavenger Settings clusters both v2.3.0 bag features for users browsing the panel.
- **Tooltip annotation now recognises the account whitelist** - The existing `[EC] Will Sell - Whitelisted` line previously only checked the per-character whitelist; account-whitelist items got no annotation. Both scopes are now consulted. Carryover gap from v2.1.0; folded in here while we were touching the tooltip code.

### v2.2.1

- **Fix: Goblin Merchant never summons after the BAG_UPDATE auto-cycle** - In v2.2.0 the new `EC_HandleBagFullForCycle` helper was placed above the `local` declarations of its `EC_summonGoblinPending` / `EC_summonGoblinTimer` flags. Lua compiled the writes inside the function as globals, so the OnUpdate consumer (which captured them as locals) never saw the trigger and the cycle hung in `WAITING_MERCHANT` with the Scavenger dismissed and no merchant summoned. The flags are now hoisted into a forward-declaration block above the helper. Same scoping trap that v2.0.13 fixed for `STATE` / `running`; same fix shape. Bonus: `_G.EC_summonGoblinPending` / `EC_summonGoblinTimer` are scrubbed at addon load so any orphan globals from a v2.2.0 session don't linger.

### v2.2.0

- **Event-driven bag detection** - The auto-loot cycle now reacts to `BAG_UPDATE` instead of a 5-second poll, so the Goblin Merchant is summoned within a tick of crossing the bag-full threshold rather than up to five seconds later. New helper `EC_HandleBagFullForCycle` is the only consumer; the pet stuck-detection and mount cooldown stay on the existing OnUpdate.
- **Fast Mode toggle** - Optional checkbox on Merchant Settings. When enabled, pins the per-item vendor interval to the 0.05 s floor and doubles the per-run cap to 160 items. Roughly halves vendoring time on large inventories. Increases disconnect risk on unstable connections; opt-in only and reversible.
- **Import / Export now supports the account whitelist** - New "Target list" radio at the top of the Import/Export panel. Pick **Character** or **Account**, then Export, Import (Merge) or Import (Replace) operates on that scope. The export string format is unchanged (`EC:<name>:<id1>,...`), so strings carry between scopes; the radio at import time decides where they land.
- **Internal: `EC_EffectiveVendorInterval` / `EC_EffectiveMaxItemsPerRun`** - Tiny accessors so Fast Mode doesn't need to mutate the user's saved `vendorInterval` / `maxItemsPerRun` values.

### v2.1.0

- **Account-wide whitelist** - New panel `Whitelist - Account` storing items in a separate `EbonClearanceAccountDB` saved variable. Both whitelists are unioned at sell time so an item listed in either fires. The character panel was renamed `Whitelist - Character` for symmetry, with the same scan-by-quality buttons on both.
- **Quality threshold moved to Merchant Settings** - The "Sell items by quality threshold" checkbox and the rarity dropdown now live alongside the other vendoring settings, freeing the Whitelist panel from clutter. Existing settings carry across automatically.
- **`/ec clean` and `/ec clean apply`** - Report and (optionally) auto-resolve item IDs present in more than one of the whitelist / blacklist / delete-list. Precedence is blacklist > delete-list > whitelist.
- **Add matching in bags** - Every list panel gets a text input that scans your bags for items whose name contains the typed substring and bulk-adds them. Useful for seasonal prefixes (e.g. `Tome of`).
- **Key bindings** - Three bindable actions under the WoW Key Bindings menu: open/close settings, toggle enabled, force sell at current merchant. These sit alongside the existing target-Goblin-Merchant binding from v2.0.13.
- **Confirmation popups on destructive actions** - Reset Lifetime Stats, Reset Session Stats, Delete Profile, and Clear Profile now ask before going through.
- **Session stats inline with lifetime** - Each lifetime stat line shows its session delta in grey alongside it, with a separate Reset Session button next to Reset Lifetime. No extra vertical space; the main page no longer overflows.
- **Panel-overflow fixes** - Reduced the default list-panel height so the bottom rows of large blacklist / delete-list / account-whitelist no longer fall outside the menu.
- **Attribution and licence change** - Replaced the MIT licence with the EbonClearance Source-Available Attribution Licence (see [LICENSE](LICENSE)). Added the in-game byline on the main panel, an SPDX-style header at the top of the Lua source, and the `EBONCLEARANCE_IDENT` / `EBONCLEARANCE_AUTHOR` / `EBONCLEARANCE_ORIGIN` globals (plus two underscore-prefixed aliases). Use, modification and redistribution still permitted - rebranding without preserved attribution is not.

### v2.0.13

- **Fix: Auto-loot cycle and pet handling were silently broken** - Four `local` variables (`STATE`, `EC_lootCycleState`, `EC_addonDismissed`, `running`) were declared after the functions that captured them, so Lua 5.1 resolved the captures to globals instead of locals. State-machine writes in `SummonGreedyScavenger` and `DismissGreedyScavenger` leaked to `_G` and never reached the OnUpdate loop; the "skip pet checks while vendoring" guard also never fired. Auto-loot cycle transitions, mount handling, and pet stuck-detection now work as documented. The errors were hidden because `EC_Delay` wrapped its callbacks in `pcall` and discarded the error; delayed-callback errors now surface through `geterrorhandler()` so real bugs don't disappear.
- **Fix: Delete-popup watcher ran every frame** - The hook that auto-confirms the delete-item dialog was ticking ~60 times per second for the entire session even when no deletion was pending. Gated on `pendingDelete` being set, plus a 0.1s accumulator.
- **Fix: `UNIT_AURA` registered unfiltered** - Now uses `RegisterUnitEvent("UNIT_AURA", "player")` where supported, so the handler doesn't wake for every aura change on every unit in a raid.
- **Feature: Tooltip annotations** - Hover any item in your bags (or a chat-linked item) and a `[EC]` line shows whether it's on your whitelist, blacklist, delete list, or matches the quality threshold. The line respects the addon-enabled state, so turning EbonClearance off via the minimap hides the annotations. Recipe tooltips that fire `OnTooltipSetItem` twice no longer show duplicate lines.
- **Feature: Mouse-over sell preview on the minimap button** - Hovering the minimap button now shows `Sellable now: N items` and an estimated value, honouring your current merchant-mode and whitelist/quality-threshold/blacklist settings. Extracted `EC_IsSellable` so the preview and the vendor loop share one predicate.
- **Feature: Optional LibDataBroker-1.0 launcher** - Users running Titan Panel, Bazooka, ChocolateBar, or similar data-broker displays get an EbonClearance entry with the same click and tooltip behaviour as the minimap button. No-op if LibStub or LDB isn't loaded - zero hard dependency.
- **Feature: Target Goblin Merchant keybinding** - A new binding appears in ESC → Key Bindings → EbonClearance. Assign any key and press it to target the Goblin Merchant - works in and out of combat. When the auto-loot cycle summons the merchant, the chat line now reads "Goblin Merchant summoned - press `<your key>` or right-click to sell" so the binding is self-discovering.
- **Internal: price-provider seam** - A new `EC_GetItemPrice` indirection sits between the vendor loop / preview and the raw `sellPrice * count` calculation. Future Auctionator-WotLK or Auctioneer probes can drop in here without touching callers.

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

## Notice

EbonClearance ships in a niche where similar inventory-management addons exist for the same private server. [NOTICE.md](NOTICE.md) documents prior art and convergent patterns honestly: which structural elements (the source-available licence shape, the provenance globals form) are adopted from conventions already present in the 3.3.5a addon ecosystem, and which (the fingerprint and watermark mechanism) are specific to this project. Read it before drawing conclusions about influence in either direction.

## Licence

This project is distributed under the EbonClearance Source-Available Attribution Licence. You may use, modify, and redistribute the addon (including in private-server addon-pack bundles) provided you preserve the author credit, the in-game byline, the provenance globals, and the LICENSE file itself, and you do not silently rebrand the addon name, the `/ec` slash command, the SavedVariable names, or the `EC:` import/export prefix. Forks under a new name are welcome as long as attribution to the original author and source URL is preserved. See the [LICENSE](LICENSE) file for the full terms.
