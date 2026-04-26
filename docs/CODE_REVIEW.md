# EbonClearance - Code Review Follow-ups

Items **not** addressed by the 2026-04-13 humanise pass. Ranked by
impact-to-risk ratio. Each is a safe-to-revert single-session change
unless noted.

---

## 1. Consolidate the two chat-filter systems - medium impact, medium risk

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

## 2. Split `CreateListUI` - high impact, low risk

[`CreateListUI`](../EbonClearance.lua) is 227 lines of UI builder
handling: title, EditBox, search box, sort buttons, scroll frame, row
pool, per-row Remove button, drag-drop handling, and a nested
`Refresh` closure with five-level sort comparators.

Suggested split:

- `BuildListHeader(parent, titleText)` - title + EditBox + search.
- `BuildListSortControls(parent, onSortChange)` - 4 sort buttons.
- `BuildListScrollArea(parent)` - the scroll frame + child.
- `MakeListRow(parent)` - one row factory; returns a frame with
  `:SetItem(id, name)` and `:Clear()` methods.
- `RefreshList(listFrame, items)` - the former nested closure.

Each helper is pure layout; no shared mutable state. Extracting pays
off every time a panel uses the list widget (whitelist, blacklist,
delete-list, any future list).

---

## 3. ~~Split `EC_petCheckFrame` OnUpdate~~ - DONE

Done in `refactor/perf-and-quality-pass`. Helpers extracted:
`EC_TickGoblinSummon`, `EC_TickGoblinTarget`, `EC_TickMerchantReminder`,
`EC_AutoLootStateSync`, `EC_HandleScavengerOut`, `EC_TryResummonScavenger`,
`EC_PetCheckTick`. The OnUpdate body is now a 9-line dispatch.

---

## 4. Consider `local EC = {}` namespace - deferred

Currently every helper is `local function EC_XxxYyy()`. This is fine
for a single file. If the file ever splits (see `docs/ADDON_GUIDE.md`
"When to split"), migrate to a shared `EC` table at the same time -
don't do it as a prerequisite.

---

## 5. L10n stub - low cost, future-proofing

Even without AceLocale, a trivial passthrough makes future localisation
mechanical:

```lua
local L = setmetatable({}, { __index = function(_, k) return k end })
-- Usage: PrintNice(L["Vendoring complete!"])
```

English keys stay English by default. When a locale table is added,
it overrides keys. Adoption is incremental - wrap new strings first,
then sweep existing ones.

---

## 6. StyLua diff once

Run `stylua EbonClearance.lua` once to normalise whitespace (mixed
blank-line runs, trailing spaces, the occasional unindented line
we fixed in the 04-13 pass).
Review the diff before committing; commit separately from any
behaviour change so `git log -p` stays legible.

---

## 7. Luacheck clean-sweep

Once `luacheck EbonClearance.lua` is runnable locally, get to zero
warnings. Likely categories:

- W113 "accessing undefined variable X" - add legitimate globals to
  `read_globals` in `.luacheckrc`.
- W211 "unused local variable" - delete the dead local, don't silence.
- W212 "unused function argument" - usually safe to `_`-prefix.
- W542 "empty if branch" - flatten or delete.

Do **not** add blanket `-- luacheck: ignore` comments.
