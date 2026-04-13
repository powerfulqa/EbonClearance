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
   Nearly everything is `local`; the only globals are `EbonClearanceDB`
   and the slash-command handles.
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

## Client target: 3.3.5a

### `.toc` fields we use

```
## Interface: 30300            # WotLK 3.3.5a; do not bump
## Title: ...                  # colour codes allowed
## Notes: ...
## Author: ...
## Version: ...
## SavedVariables: EbonClearanceDB
```

If you ever add a character-scoped var, use `## SavedVariablesPerCharacter`.
We do not use `Dependencies`, `OptionalDeps`, `LoadOnDemand`, or
`LoadManagers`.

### Lua 5.1 constraints

- No `goto` / labels.
- No integer division operator (`//`) - use `math.floor(a / b)`.
- No `bit32`; use the built-in `bit` library (`bit.band`, `bit.bor`, etc).
- No `string.pack`, no `utf8` library.
- `ipairs` stops at the first nil; use `pairs` for sparse tables.

## Architecture

### File layout

One file, roughly in this order:
- Constants and cached API upvalues (top).
- Greedy Scavenger chat filters (`EC_GreedyEventFilter`,
  `EC_InstallGreedyMuteOnce`, `ApplyGreedyChatFilter`).
- Speech-bubble killer (`EC_bubbleFrame`).
- SavedVariable bootstrap (`EnsureDB`).
- Profile / bag / pet / merchant helpers.
- State machine constants (`STATE`).
- Timers (`EC_Delay`, `EC_delayFrame`).
- Pet check OnUpdate and auto-loot cycle (`EC_petCheckFrame`).
- Vendor loop (`BuildQueue`, `DoNextAction`, `worker`).
- UI: `CreateListUI`, minimap button, Interface Options panels.
- Export / import / bug report.
- Event dispatch (bottom) and slash commands.

Approximate ordering - do not reshuffle unless splitting the file.

### The event hub

At the bottom of the file, one `CreateFrame("Frame")` registers every
event and dispatches via a switch on `event`. Adding a new event is a
two-liner: `f:RegisterEvent("NEW_EVENT")` and a branch in the OnEvent
handler. Do **not** add a second event frame for "your feature."

### Saved variables shape

`EbonClearanceDB` is one flat table. Fields fall into four groups:

- **Lists**: `whitelist`, `blacklist`, `deleteList`, `enableOnlyListedChars`.
- **Profiles**: `whitelistProfiles`, `blacklistProfiles`, `activeProfileName`.
- **Settings**: `enabled`, `summonGreedy`, `summonDelay`,
  `vendorInterval`, `merchantMode`, `autoLootCycle`, `bagFullThreshold`,
  `repairGear`, `keepBagsOpen`, `muteGreedy`, `hideGreedyChat`,
  `hideGreedyBubbles`, `enableDeletion`, `whitelistMinQuality`,
  `whitelistQualityEnabled`.
- **Stats**: `totalCopper`, `totalItemsSold`, `totalItemsDeleted`,
  `totalRepairs`, `totalRepairCopper`, `soldItemCounts`,
  `deletedItemCounts`, `inventoryWorthTotal`, `inventoryWorthCount`.
- **UI**: `minimapButtonAngle`, `allowedChars`.

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
- `/ec bugreport` - diagnostic dump for issue reports.
- `/ecdebug` - debug info plus bag scan.

Slash commands are registered at the very bottom of `EbonClearance.lua`.

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

## When to split the file

Keep the single-file layout until one of these is true:

- File exceeds ~4000 LOC.
- Two largely-independent features share almost no state.
- We adopt Ace3, at which point AceAddon lifecycle encourages modules.

If you do split: introduce a `local EC = {}` namespace table in a new
`EbonClearance_Core.lua`, loaded first in the `.toc`, and have each
feature file attach to it. Do **not** split mid-feature - keep bag
code together, vendor code together, UI together.
