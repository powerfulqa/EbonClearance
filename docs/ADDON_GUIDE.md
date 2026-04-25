# EbonClearance - Addon Development Guide

**Read this first if you are an AI agent or new contributor touching
this codebase.** It is prescriptive: when the guide and a random
internet tutorial disagree, follow the guide.

## TL;DR conventions

1. **Client target is WoW 3.3.5a (Interface 30300 / WotLK / Lua 5.1).**
   Do not copy-paste retail code. APIs like `C_Timer`, `C_Container`,
   and `BAG_UPDATE_DELAYED` do not exist here.
2. **Single file.** All code lives in `EbonClearance.lua`. Do not split
   into modules unless explicitly asked - see "When to split" below.
3. **Namespace via `EC_` prefixed locals.** There is no addon table.
   Nearly everything is `local`; the only intentional globals are the
   saved-variable tables (`EbonClearanceDB`, `EbonClearanceAccountDB`),
   the slash-command handles, the keybinding header / name strings
   (`BINDING_HEADER_EBONCLEARANCE`, `BINDING_NAME_EBONCLEARANCE_*`), the
   handlers wired from `Bindings.xml` (`EbonClearance_ToggleSettings`,
   `EbonClearance_ToggleEnabled`, `EbonClearance_ForceSell`), and the
   provenance globals required by `LICENSE` §2 (`EBONCLEARANCE_IDENT`,
   `EBONCLEARANCE_AUTHOR`, `EBONCLEARANCE_ORIGIN`,
   `__EbonClearance_origin`, `__EbonClearance_author`).
4. **State machine uses `STATE.*` constants**, never raw strings. See
   `STATE = { IDLE, LOOTING, WAITING_MERCHANT, SELLING }` in the file.
5. **Cache hot WoW API globals at file top**, then use the locals on
   hot paths (vendor loop, bag scans, OnUpdate callbacks).
6. **One event-dispatch frame.** All events hang off `f` at the bottom
   of `EbonClearance.lua`. Do not create new event frames for new events
   - add to the dispatch table.
7. **Print through `PrintNice` or `PrintNicef`.** Never call
   `DEFAULT_CHAT_FRAME:AddMessage` directly outside those helpers.
8. **Saved variables always go through `EnsureDB()`.** New fields must
   default without breaking an existing `EbonClearanceDB` table.
9. **Interface Options panels are idempotent via `self.inited`.** Every
   panel's OnShow does the "if inited then refresh-only; return" dance.
10. **No external libraries.** No Ace3, no LibStub, no LDB. See the
    Ace3 decision record below for the reasoning and escape hatch.
11. **Doc links never use `#L<n>` line anchors.** Link to the file by
    name (e.g. `[CreateListUI](../EbonClearance.lua)`) and let readers
    `grep` for the symbol. Line numbers shift on every refactor; symbol
    names don't.
12. **Do not remove attribution markers.** `LICENSE` §2 lists five
    things every redistribution must preserve: the `## Author:` TOC
    line, the file-header comment block at the top of
    `EbonClearance.lua`, the GUI byline rendered on the main options
    panel, the `EBONCLEARANCE_*` / `__EbonClearance_*` provenance
    globals, and the `LICENSE` file in full. If a refactor would touch
    any of those, leave them alone or update them with care - never
    delete.

## Client target: 3.3.5a

### `.toc` fields we use

```
## Interface: 30300                                # WotLK 3.3.5a; do not bump
## Title: ...                                      # colour codes allowed
## Notes: ...
## Author: ...                                     # required by LICENSE §2(a)
## X-Website: https://github.com/.../EbonClearance # canonical source
## Version: ...
## SavedVariables: EbonClearanceDB, EbonClearanceAccountDB

EbonClearance.lua
Bindings.xml
```

`EbonClearanceDB` is per-character (default for `## SavedVariables`);
`EbonClearanceAccountDB` is account-wide and stores the shared
whitelist that gets unioned at sell time. If you ever add a
character-scoped var that should *not* persist across characters in
this account, use `## SavedVariablesPerCharacter`. We do not use
`Dependencies`, `OptionalDeps`, `LoadOnDemand`, or `LoadManagers`.

`Bindings.xml` declares the three bindable actions and is loaded
straight after the Lua. Do not move bindings into Lua - WoW expects
them in XML at addon-load time.

### Lua 5.1 constraints

- No `goto` / labels.
- No integer division operator (`//`) - use `math.floor(a / b)`.
- No `bit32`; use the built-in `bit` library (`bit.band`, `bit.bor`, etc).
- No `string.pack`, no `utf8` library.
- `ipairs` stops at the first nil; use `pairs` for sparse tables.

## Architecture

### File layout

One file, roughly in this order:
- File header comment block (required by LICENSE §2(b); do not remove).
- Constants and cached API upvalues (top).
- Provenance globals (`EBONCLEARANCE_IDENT/AUTHOR/ORIGIN`, plus two
  `__EbonClearance_*` aliases - required by LICENSE §2(d)).
- Greedy Scavenger chat filters (`EC_GreedyEventFilter`,
  `EC_InstallGreedyMuteOnce`, `ApplyGreedyChatFilter`).
- Speech-bubble killer (`EC_bubbleFrame`).
- SavedVariable bootstrap (`EnsureDB`, `EnsureAccountDB`,
  `EC_GetListTable` list-name resolver, `EC_ExtraListTables`).
- Profile / bag / pet / merchant helpers.
- State machine constants (`STATE`).
- Timers (`EC_Delay`, `EC_delayFrame`).
- Session-stats table (`EC_session`) and `EC_ResetSession`.
- Pet check OnUpdate and auto-loot cycle (`EC_petCheckFrame`).
- Vendor loop (`BuildQueue`, `DoNextAction`, `worker`).
- UI: `CreateListUI` (search / sort / "Add matching in bags" row baked
  in), minimap button, dormant `EC_CreateVendorButton`,
  `StaticPopupDialogs` for confirmation, Interface Options panels
  (Main, Merchant Settings - includes the quality threshold,
  Whitelist - Character, Whitelist - Account, Profiles, Import/Export,
  Deletion List, Blacklist - Keep, Scavenger Settings, Character
  Settings).
- `EC_AddScanByQualityRow` helper used by both whitelist panels.
- Export / import / bug report.
- List-conflict helpers (`EC_ScanListConflicts`,
  `EC_PrintConflictReport`, `EC_ApplyCleanResolution`).
- Keybinding header / name strings and the three
  `EbonClearance_*` global handlers (called from `Bindings.xml`).
- Event dispatch (bottom) and slash commands (`/ec`, `/ec profile ...`,
  `/ec clean [apply]`, `/ec bugreport`, `/ecdebug`).

Approximate ordering - do not reshuffle unless splitting the file.

### The event hub

At the bottom of the file, one `CreateFrame("Frame")` registers every
event and dispatches via a switch on `event`. Adding a new event is a
two-liner: `f:RegisterEvent("NEW_EVENT")` and a branch in the OnEvent
handler. Do **not** add a second event frame for "your feature."

### Saved variables shape

`EbonClearanceDB` is one flat table per character. Fields fall into
four groups:

- **Lists**: `whitelist`, `blacklist`, `deleteList`, `enableOnlyListedChars`.
- **Profiles**: `whitelistProfiles`, `blacklistProfiles`, `activeProfileName`.
- **Settings**: `enabled`, `summonGreedy`, `summonDelay`,
  `vendorInterval`, `merchantMode`, `autoLootCycle`, `bagFullThreshold`,
  `repairGear`, `keepBagsOpen`, `muteGreedy`, `hideGreedyChat`,
  `hideGreedyBubbles`, `enableDeletion`, `whitelistMinQuality`,
  `whitelistQualityEnabled`, `vendorBtnShown` (and `vendorBtnX`,
  `vendorBtnY`, `vendorBtnPoint`, `vendorBtnRelPoint` - dormant; see the
  `EC_CreateVendorButton` block).
- **Stats**: `totalCopper`, `totalItemsSold`, `totalItemsDeleted`,
  `totalRepairs`, `totalRepairCopper`, `soldItemCounts`,
  `deletedItemCounts`, `inventoryWorthTotal`, `inventoryWorthCount`.
- **UI**: `minimapButtonAngle`, `allowedChars`.

`EbonClearanceAccountDB` is a separate, account-wide table holding only
`{ whitelist = { [itemID] = true, ... } }`. It is bootstrapped by
`EnsureAccountDB()` (called from `EnsureDB()`) and exposed to
`CreateListUI` via the `EC_GetListTable` resolver under the name
`accountWhitelist`. Sell-time consultation is a union of the per-char
and account whitelists.

In-memory only (not saved): `EC_session = { copper, sold, deleted,
repairs, repairCopper }`. Reset by the Reset Session button on the main
page or on `/reload`.

`EnsureDB()` is the **only** place defaults are written. Adding a new
setting means: pick the group, add a default line inside `EnsureDB()`,
and make sure it's `nil`-tolerant (`DB.myField or default`).

## Required patterns

### Locals everywhere

```lua
local function DoThing()  -- good
function DoThing()        -- bad - creates a global
```

Check with `luacheck EbonClearance.lua`; the W111/W112 family catches
this.

### Cached API globals

The block at the top of the file caches hot API functions:

```lua
local GetItemInfo = GetItemInfo
local GetContainerItemID = GetContainerItemID
-- ...and the rest of the bag / merchant / companion API
```

When you use one of these on a hot path, you are using the local
upvalue, which is a single register read rather than a `_G` hash
lookup. If you add new hot-path API calls, add them to the cache.

### State transitions

```lua
EC_lootCycleState = STATE.LOOTING          -- good
EC_lootCycleState = "looting"              -- bad - typos become silent
if EC_lootCycleState == STATE.IDLE then    -- good
```

A typo in a string state is a silent bug (the comparison fails, the
transition never fires). A typo in `STATE.XYZ` is a nil-compare that
fails closed and usually crashes loudly.

### Chat output

```lua
PrintNice("Hello")                          -- static string
PrintNicef("Sold %d items for %s", n, g)    -- formatted
-- never:
DEFAULT_CHAT_FRAME:AddMessage("[EbonClearance] ...")
```

The prefix/colour are owned by `PrintNice`. Direct `AddMessage` calls
drift the prefix over time.

### Event handler

Add to the hub's switch, do not spawn a new frame:

```lua
-- In the bottom event handler:
elseif event == "BAG_UPDATE" then
    -- new branch
```

## UI conventions

### Interface Options panels

Pattern for every panel:

```lua
local MyPanel = CreateFrame("Frame", "EbonClearanceOptionsMy",
    InterfaceOptionsFramePanelContainer)
MyPanel.name = "My Panel"
MyPanel.parent = "EbonClearance"           -- nest under main category

MyPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        -- refresh dynamic widgets from DB here, then
        return
    end
    self.inited = true
    -- static widget creation (called exactly once)
end)

InterfaceOptions_AddCategory(MyPanel)
```

### Colour palette

Use the existing palette - do not invent new shades:

| Colour code  | Meaning         |
|--------------|-----------------|
| `\|cff4db8ff` | Addon title     |
| `\|cffb6ffb6` | Success / good  |
| `\|cffff4444` | Error / bad     |
| `\|cffffb84d` | Warning / note  |
| `\|cffffff00` | Emphasis yellow |
| `\|cff7fbfff` | Chat prefix     |
| `\|cff888888` | Muted / caption |

## Performance rules for 3.3.5a

- **Never do a full bag scan per frame.** OnUpdate scripts that run
  every frame must early-return unless an accumulator threshold
  (`elapsed`, interval counter) has elapsed. See `EC_petCheckFrame`
  for the canonical 5-second-tick pattern.
- **`GetItemInfo` returns `nil` for uncached items.** The canonical
  warm-up is a hidden `GameTooltip:SetHyperlink()` which forces the
  client to request the item data. After a short delay, `GetItemInfo`
  will return the real values. `CreateListUI` uses this pattern.
- **Vendor interval floor is 0.05s.** The server disconnects addons
  that hammer the merchant. Do not reduce the floor in
  `DB.vendorInterval` bounds.
- **`wipe(t)` is preferred over `t = {}`** when clearing a table that
  has external references (saved variables, widgets holding a ref).

## Saved variables

Always go through `EnsureDB()`. The function is idempotent and migrates
the legacy `EbonholdStuffDB` on first run. Adding a new field:

```lua
if type(DB.myNewField) ~= "number" then DB.myNewField = 0.5 end
```

Pick the type-tolerant form (`type(...) ~= "expected"`) so manually-
edited saved variables don't corrupt the addon.

Do **not** hard-delete fields when you rename; leave a migration:

```lua
if DB.oldName ~= nil and DB.newName == nil then
    DB.newName = DB.oldName
    DB.oldName = nil
end
```

## Ace3 - decision record

**We do not embed Ace3 in EbonClearance.** Reasoning:

- The addon works and is stable. A library migration is a rewrite, not
  a refactor.
- Ace3 embed is ~200KB of code for an addon that uses maybe 10% of
  the surface.
- 3.3.5a private servers sometimes gate on file sizes or forbid certain
  embedded libs. Shipping plain Lua avoids that friction.

If we ever did migrate, the minimum-viable Ace3 stack for this addon
would be:

| Library              | Replaces                                   |
|----------------------|--------------------------------------------|
| AceAddon-3.0         | The `ADDON_LOADED` / `PLAYER_LOGIN` dance  |
| AceDB-3.0            | `EnsureDB`, profile handling, per-char DBs |
| AceConfig-3.0 +      | Eight manual `InterfaceOptionsFramePanelContainer` |
| AceConfigDialog-3.0  | panels collapse to one options table       |
| AceTimer-3.0         | The four OnUpdate timer frames             |

Use a WotLK-compatible Ace3 revision (r1196–r1249 era; verify
`## Interface: 30300` on the tagged release before embedding).

**What we steal without embedding.** The *shape* of AceConfig's options
table (`type`, `name`, `desc`, `order`, `get`, `set`) is worth
imitating even in vanilla code. If we rebuild our options UI, structure
it as an AceConfig-style table first - future migration becomes a
mechanical substitution.

## Tooling

### StyLua (formatter)

```
stylua EbonClearance.lua            # rewrite
stylua --check EbonClearance.lua    # CI-style verify
```

Config is `stylua.toml`. 4-space indent, 120-column wrap, double
quotes preferred. Matches the existing file style - adopting it
produces no churn.

### Luacheck (linter)

```
luacheck EbonClearance.lua
```

Config is `.luacheckrc`. Goal is zero warnings. If Luacheck flags a
WoW global we actually use, add it to `read_globals` - don't silence
the whole check.

### Qlty-aligned smell gates

Not wired into CI, but enforce in review:

- Functions over 80 LOC → extract helpers. (OnShow / OnUpdate closures
  may exceed this when building UI; prefer to split the init branch
  into a helper, see `BuildMainPanel`.)
- Nesting depth over 4 → flatten with early-return or extract a
  predicate.
- Argument lists over 5 → pack into an options table.
- Identical or near-identical code blocks over 6 lines → extract. See
  `runImport` (import Merge/Replace dedupe) as the canonical example.

## Slash commands

- `/ec` - open the Interface Options panel.
- `/ec profile list|save|load|delete <name>` - profile management.
- `/ec clean` - report items present on more than one list.
- `/ec clean apply` - auto-resolve list conflicts (precedence:
  blacklist > deleteList > whitelist).
- `/ec bugreport` - diagnostic dump for issue reports.
- `/ecdebug` - debug info plus bag scan.

Key bindings (declared in `Bindings.xml`, handlers near the slash
commands):

- `EBONCLEARANCE_TOGGLE_SETTINGS` → `EbonClearance_ToggleSettings()`.
- `EBONCLEARANCE_TOGGLE_ENABLED` → `EbonClearance_ToggleEnabled()`.
- `EBONCLEARANCE_FORCE_SELL` → `EbonClearance_ForceSell()`.

Slash commands and binding handlers are registered at the very bottom
of `EbonClearance.lua`.

## 3.3.5a gotchas

- **Item links.** The only stable part of the hyperlink is the item ID.
  Parse with `link:match("|Hitem:(%d+)")` - do not parse bonus IDs,
  level info, or the post-Legion modifiers. They don't exist here.
- **No `C_Timer.After`.** Use `EC_Delay(seconds, func)`.
- **`GetContainerItemInfo` return signature.** 3.3.5a returns
  `texture, itemCount, locked, quality, readable, lootable, itemLink`.
  Retail reinvented this call three times. Never copy-paste retail.
- **`ChatFrame_AddMessageEventFilter` is global.** Once added, the
  filter runs for every ChatFrame. If you install one, track the
  installation with a module-level boolean (`EC_greedyFiltersInstalled`)
  so a `/reload` doesn't double-register.
- **`PLAYER_ENTERING_WORLD` fires after every zone transition**, not
  just login. Guard expensive one-time work with a `local inited`
  boolean.
- **No `C_Timer`, no `Mixin`, no `SecureHandler` templates** at the
  richness you'd find in retail. If a tutorial assumes those, it's not
  for 3.3.5a.

## Gotchas and refactoring traps

Read this section before touching any of the subsystems below. Each item is
a non-obvious design choice that has silently broken in the past (or would
if you "simplified" it).

### Saved-variable migration order is load-bearing

`EnsureDB()` does two migrations in a specific order that must not be reshuffled:

1. **Legacy rename**: if `EbonholdStuffDB` exists and `EbonClearanceDB` does
   not, rename the former into the latter. This has to happen first because
2. **Profile migration**: when the profile-aware schema first runs, it
   snapshots any existing `DB.whitelist` into an `"Imported"` profile and
   auto-activates it. If the legacy rename hasn't happened yet, `DB.whitelist`
   is empty and the user's pre-profile data is lost.

If you add a new migration, put it with the others at the top of
`EnsureDB()` and write the order dependency into the comment.

### Grey items are always sold, independent of every other setting

In `EC_IsSellable`, three independent predicates (`isJunk`, `qualityPass`,
`whitelistPass`) are ORed together. `isJunk` fires on `quality == 0 and
hasSellPrice`. This means grey items with a positive sell price are *always*
matched -- the quality-threshold toggle and the whitelist have no say.

Do not combine the three passes into "one cleaner check." You will silently
break the grey-always-sold invariant that users and the README rely on. The
only things that can veto a match are `IsEquippedItem(itemID)` and the
blacklist, both of which are safety gates.

### Localisation: `TARGET_NAME` / `PET_NAME` are enUS strings

`TARGET_NAME = "Goblin Merchant"` and `PET_NAME = "Greedy scavenger"` are
compared directly against `creatureName` returned by `GetCompanionInfo`. A
non-enUS realm with localised NPC names would silently fail both lookups.

`FindGoblinMerchantIndex` already has a `spellID == 600126` fallback which
is the localisation escape hatch. If a future user reports "summoning
doesn't work on Ebonhold-EU," add a matching spellID fallback to
`SummonGreedyScavenger` rather than trying to translate the names.

### The `"CRITTER"` companion type covers both pet and merchant

On 3.3.5a, the Goblin Merchant and the Greedy Scavenger both occupy the
`"CRITTER"` companion slot despite one being a vanity pet and the other a
functional merchant. They **cannot coexist**. That's why summoning the
merchant dismisses the Scavenger and vice versa, and why the auto-loot
cycle's `WAITING_MERCHANT` / `SELLING` states explicitly dismiss before
re-summoning.

If you want to add a third `CRITTER` feature, know that it will mutually
exclude with the existing two.

### The auto-loot cycle resets on `MERCHANT_CLOSED`, not before

`EC_lootCycleState` transitions to `IDLE` only when `MERCHANT_CLOSED` fires
(plus the `FinishRun` happy path). If a user dismisses the Goblin Merchant
manually without ever opening the vendor window, the state stays at
`WAITING_MERCHANT` indefinitely, and the 5-second pet-check tick won't
re-summon the Scavenger until either the 8-second reminder timer lapses or
another event resets state.

If you ever add a new "we've given up on this sell" path, also clear
`EC_lootCycleState` to `IDLE` or `LOOTING` explicitly -- don't assume the
normal `MERCHANT_CLOSED` flow will rescue it.

### `EC_Delay` callbacks must surface errors via `geterrorhandler`

The custom `EC_Delay` timer wraps each callback in `pcall`. Without a
follow-up call to `geterrorhandler()(err)`, errors inside delayed callbacks
disappear silently -- which is exactly what hid the v2.0.13 scoping bugs
for several releases.

If you add a new delayed-callback helper (or a new timer frame), route
errors the same way `EC_Delay` does. Do not add new bare `pcall` swallows.

### Delete-list seeding is deliberately empty

`EnsureDB()` still has a `_seededLists` one-shot flag, but the list it used
to seed (item IDs 300581 and 300574) was removed as stale cruft. Empty
delete list on first install is intentional. If a future scenario needs to
pre-populate specific IDs, use the `_seededLists` guard to avoid re-seeding
existing users.

### `UnitPosition` does not exist on stock 3.3.5a

`EC_GetCompanionDistance` gates on `if not UnitPosition then return nil end`.
On unmodified 3.3.5a clients the check no-ops the entire distance-stuck
detection feature. Project Ebonhold's build apparently exposes it (the
feature works in-game), but do not assume it on other private servers.

### Index of magic numbers

| Value | Location | Meaning |
|---|---|---|
| 0.05s | vendor worker OnUpdate | Per-item pacing floor. Below this, the server boots you for packet spam. |
| 5 yards | `EC_MAX_PET_DISTANCE` | Scavenger-drift threshold before dismiss-and-resummon. |
| 80 items | `maxItemsPerRun` | Sell-queue cap per run. Prevents the same disconnect risk as the vendor-interval floor. Recursive batching kicks in for larger inventories. |
| 1.5s | `EC_summonGoblinTimer` | Wait between dismiss and Goblin Merchant summon so the client has time to process the companion switch. |
| 2.0s | `EC_targetGoblinTimer` | Wait after summon before checking `isSummoned` via `GetCompanionInfo`. |
| 8.0s | `EC_merchantReminderTimer` | Gap before we remind the user to right-click the merchant (or use their keybind). |
| 10s | `EC_mountDismissTime` cooldown | Suppress pet re-summon within 10s of a mount-dismount to avoid cancelling the mount cast. |
| 600126 | `GOBLIN_MERCHANT_SPELL_ID` | Companion spell ID for the Goblin Merchant, used as the localisation escape hatch. |

If you change any of these, update this table and the nearest comment.

## When to split the file

Keep the single-file layout until one of these is true:

- File exceeds ~4000 LOC.
- Two largely-independent features share almost no state.
- We adopt Ace3, at which point AceAddon lifecycle encourages modules.

If you do split: introduce a `local EC = {}` namespace table in a new
`EbonClearance_Core.lua`, loaded first in the `.toc`, and have each
feature file attach to it. Do **not** split mid-feature - keep bag
code together, vendor code together, UI together.
