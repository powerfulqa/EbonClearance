# EbonClearance - Code Review Follow-ups

A curated backlog of known follow-ups not yet actioned. Each item is
scoped to be a single-session change unless flagged otherwise.

> **Last refresh:** post-v2.6.0 on 2026-04-26.
> Statuses below verified against the current `EbonClearance.lua`
> (5561 LOC). Items that have shipped are listed under
> [Resolved](#resolved) at the bottom.

---

## Active backlog

### 1. Consolidate the two chat-filter systems - medium impact, medium risk

Two independent filter installations coexist:

- [`EC_InstallGreedyMuteOnce`](../EbonClearance.lua) installs
  `EC_GreedyEventFilter` across 10 chat events.
- [`ApplyGreedyChatFilter`](../EbonClearance.lua) installs
  `GreedyScavengerChatFilter` across the events listed in
  [`CHAT_FILTER_EVENTS`](../EbonClearance.lua).

Both currently run; the mute behaviour is layered (each filter early-
returns when its condition isn't met). Consolidating to one system
would simplify reasoning but risks regressing edge cases - especially
around `CHAT_MSG_MONSTER_*` vs `CHAT_MSG_SAY` dispatch when the
Scavenger is nearby other mobs.

**Approach if picked up**: audit both filter functions side-by-side,
produce a truth table for every input (muteGreedy × hideGreedyChat ×
hideGreedyBubbles × event-type), and collapse to a single filter that
satisfies the table. Keep the old functions in a feature branch and
do side-by-side testing in a stable zone before deleting.

---

### 2. Split [`CreateListUI`](../EbonClearance.lua) - high impact, low risk

`CreateListUI` is now **369 lines** (was 227 when this doc was first
written). Since then the v2.x.0 series added the "Add matching in
bags:" row, account / character scope handling, and tooltip-warm
refresh logic - all bolted onto the same closure.

Suggested split (still the right shape, plus the new responsibilities
above):

- `BuildListHeader(parent, titleText)` - title + EditBox + search.
- `BuildListSortControls(parent, onSortChange)` - 4 sort buttons.
- `BuildListMatchRow(parent, setTableName, refreshFn)` - the
  "Add matching in bags:" row + handler.
- `BuildListScrollArea(parent)` - the scroll frame + child.
- `MakeListRow(parent)` - one row factory; returns a frame with
  `:SetItem(id, name)` and `:Clear()` methods.
- `RefreshList(listFrame, items)` - the former nested closure.

Each helper is pure layout; no shared mutable state. Extracting pays
off every time a panel uses the list widget (whitelist, blacklist,
delete-list, account whitelist, any future list).

---

### 3. `local EC = {}` namespace - decision required

Originally framed as "deferred until the file ever splits". That
predicate has been overtaken: the file is now **5561 LOC**, well
past the **~4000 LOC** split threshold documented in
[`docs/ADDON_GUIDE.md`](ADDON_GUIDE.md) "When to split the file".

Decision needed:

- **Stay single-file** and accept the size. CLAUDE.md and ADDON_GUIDE
  should be updated to bump the threshold (or remove it).
- **Split into modules** along feature seams (vendor loop / pet
  management / UI panels / list helpers / export-import). At that
  point the `local EC = {}` namespace stops being a stylistic
  preference and becomes load-bearing - cross-file shared state has
  to live somewhere.

Either resolution closes this item. Do not migrate to `EC = {}`
without committing to one of the above; doing it for its own sake on
a single file is pure churn.

---

### 4. L10n stub - low cost, future-proofing

Even without AceLocale, a trivial passthrough makes future
localisation mechanical:

```lua
local L = setmetatable({}, { __index = function(_, k) return k end })
-- Usage: PrintNice(L["Vendoring complete!"])
```

English keys stay English by default. When a locale table is added,
it overrides keys. Adoption is incremental - wrap new strings first,
then sweep existing ones.

Status: still applicable, still nobody asking for it. Park unless a
concrete localisation request lands.

---

### 5. Luacheck clean-sweep - partially done

Current state: **71 warnings, 0 errors** (under the documented 93-
warning baseline in `CLAUDE.md`, but not at zero). `.luacheckrc` is
checked in; running locally requires the toolchain - see the
[For Contributors](../README.md#for-contributors) section.

Categories observed in the current run (a starting checklist for the
next pass):

- **Undeclared globals**: `GetCursorInfo`, `GetUnitSpeed`,
  `WorldFrame`, `DB`. Add the first three to
  [`.luacheckrc`](../.luacheckrc) `read_globals`. `DB` is a
  forward-declared local that Luacheck can't follow - either treat
  as a global, add a per-section `-- luacheck: globals DB` directive,
  or restructure the forward declaration.
- **Unused cached API locals**: `GetMerchantNumItems`,
  `GetMerchantItemInfo`, `GetMerchantItemLink`, `PET_CHAT_PREFIX`.
  Either delete (if truly unused now) or use them where intended -
  do not silence with `_` rename.
- **Unused arguments / varargs**: `event`, `...` on chat filter
  handlers. Standard fix: rename to `_event`, drop `...` if not
  forwarded.
- **`msg` shadowing**: a handful of inner `msg` locals shadow the
  outer chat handler argument. Rename inner ones to `chatMsg` (or
  similar) to stop the shadow.

Do not add blanket `-- luacheck: ignore` comments. Each remaining
warning, if any, should have a per-line explanation.

---

## Resolved

### Split [`EC_petCheckFrame`](../EbonClearance.lua) OnUpdate - DONE (v2.4.0)

Done in `refactor/perf-and-quality-pass`. Helpers extracted:
`EC_TickGoblinSummon`, `EC_TickGoblinTarget`, `EC_TickMerchantReminder`,
`EC_AutoLootStateSync`, `EC_HandleScavengerOut`, `EC_TryResummonScavenger`,
`EC_PetCheckTick`. The OnUpdate body is now a small dispatch.

### StyLua diff once - DONE

`stylua --check EbonClearance.lua` is clean and has been kept clean
across multiple recent commits. The formatter runs as part of every
release-prep pass.
