# Spec: Gold-per-hour stats (session + best persistent)

**Date**: 2026-05-26
**Status**: Approved (brainstorming complete; awaiting implementation plan)
**Target release**: v2.35.0 (next minor, since v2.34.1 is a patch release for the Most Sold Item regression)
**Touched files**: `EbonClearance_Events.lua`, `EbonClearance_MainPanel.lua`, `tests/test_perf_guardrails.lua`

## Goal

Add two new stats to the Statistics block on the Main panel:

1. **Session Gold/Hour** - a live rate showing how fast the current session is earning gold via EC's vendor cycle.
2. **Best Gold/Hour** - the highest sustained session-GPH this character has ever reached, with the zone + date it was achieved.

Both are personal-best motivational metrics, not leaderboard contenders. Leaderboard support is explicitly out of scope (see "Out of scope" below).

## Data shape

### New `EC_session` field (in-memory)

| Field | Type | Default | Set when | Wiped when |
|---|---|---|---|---|
| `startedAt` | number (GetTime() seconds) | `0` | `EC_ResetSession()` is called at PLAYER_LOGIN's first EnsureDB OR the Reset Session Stats button | `/reload` (whole EC_session table is wiped naturally - it's a file-scope local) |

`EC_ResetSession` is updated to set `EC_session.startedAt = GetTime()` alongside zeroing the existing counters. The function already exists; this is a 1-line addition.

### New per-character DB fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `bestGPH` | number (copper-per-hour rate) | `0` | Stored as raw copper; existing `NS.CopperToColoredText` formats it without modification (treats the number as copper and renders g/s/c, which is exactly what we want for a per-hour rate). |
| `bestGPHAt` | number (epoch seconds from `time()`) | `0` | Unix-style timestamp at the moment `bestGPH` was last set. WoW's `time()` returns this format directly. |
| `bestGPHZone` | string | `""` | `GetRealZoneText()` snapshot at the moment `bestGPH` was last set. Falls back to `"Unknown"` if the API returns empty or nil. |

All three are added to `PER_CHAR_FIELDS` in `EbonClearance_Events.lua` so the v2.34.0 per-character partition migrates them correctly for new characters. A character whose snapshot has no `bestGPH` field starts at `0` (the field is additive; the existing snapshot-based seeding handles "missing field" the same as "default value").

## Calculation

Inside `RefreshStats()` in `EbonClearance_MainPanel.lua`:

```lua
local startedAt = NS.session.startedAt or 0
local elapsed = (startedAt > 0) and (GetTime() - startedAt) or 0
local sessionGPH
if elapsed >= 10 then
    sessionGPH = math.floor((NS.session.copper / elapsed) * 3600)
else
    sessionGPH = nil  -- "computing" state; avoid sub-10s extrapolation
end
```

The 10-second floor prevents absurd extrapolations when the panel is opened immediately after `/reload` or after Reset Session Stats. Below the floor the display shows a placeholder (see Display below).

## Best-update logic

```lua
if elapsed >= 300 and sessionGPH and sessionGPH > (DB.bestGPH or 0) then
    DB.bestGPH = sessionGPH
    DB.bestGPHAt = time()
    DB.bestGPHZone = (GetRealZoneText() and GetRealZoneText() ~= "") and GetRealZoneText() or "Unknown"
end
```

- 300 seconds (5 minutes) is the minimum session duration before the best can update. This filters out early-session burst noise (selling one grey 3 seconds after `/reload` would otherwise lock the best at ~1800 g/h forever).
- The three fields are written together atomically (no partial writes; if `bestGPH` updates, the timestamp and zone always update with it).
- `DB.bestGPHZone` uses the result of `GetRealZoneText()`, which returns the current real zone the player is in. Sub-zones (e.g., "The Stockade" within Stormwind) are NOT used; the macro-zone is more useful as a "where did I farm" tag. Fallback to "Unknown" handles the edge case where the API returns empty during a zone transition.

The update fires inside `RefreshStats()`, which already runs on panel show + after every merchant cycle. This means:

- Opening the Stats panel mid-farm checks the current session and potentially updates the best.
- The post-merchant-cycle refresh also checks, so best updates happen at the natural endpoint of a sell run without needing the user to open `/ec`.

## Display

Two new lines on the Statistics block, inserted after `Total Repair Cost` and before `Average Inventory Worth`:

```
Total Money Made: 65g 90s 3c  (session +12g 34s)
Total Items Sold: 253452  (session +47)
Total Items Deleted: 180  (session +2)
Total Repairs: 397  (session +0)
Total Repair Cost: 534g 90s 37c  (session +0)
Session Gold/Hour: 145g 23s 4c  (5m 12s)
Best Gold/Hour: 234g 56s 7c
  in Stranglethorn Vale, 3 days ago
Average Inventory Worth: 12g 34s 56c
Most Sold Item: Linen Cloth (x3505)
```

### Session line formatting

- `Session Gold/Hour: <rate>  (<elapsed>)` where `<rate>` is `NS.CopperToColoredText(sessionGPH)` and `<elapsed>` is a humanised duration (`12s`, `5m 12s`, `1h 23m 4s`).
- During the first 10 seconds: `Session Gold/Hour: -  (computing...)`.
- When `EC_session.copper == 0` and elapsed > 10s: `Session Gold/Hour: 0g 0s 0c  (<elapsed>)`. Zero is a legitimate value; show it.

### Best line formatting

- Line 1: `Best Gold/Hour: <rate>` where `<rate>` is `NS.CopperToColoredText(DB.bestGPH)`.
- Line 2 (indented two spaces): `in <zone>, <when>`. The `when` is a relative humanised duration when recent, absolute date when old:
  - `< 60s` -> "just now"
  - `< 1h` -> "N minute(s) ago"
  - `< 24h` -> "N hour(s) ago"
  - `< 30 days` -> "N day(s) ago"
  - `>= 30 days` -> `date("%Y-%m-%d", DB.bestGPHAt)`
- If `DB.bestGPH == 0` (never set): single-line `Best Gold/Hour: -` with no context line.

## Reset semantics

- **Reset Session Stats button** (existing): already calls `EC_ResetSession()`. After the spec lands, that function also resets `EC_session.startedAt = GetTime()`. The session GPH line displays "computing..." for the next 10 seconds.
- **Reset Lifetime button** (existing): already zeroes the cumulative DB fields. After the spec lands, it also zeroes `bestGPH`, `bestGPHAt`, `bestGPHZone`. A user choosing "wipe my lifetime stats" wipes the best record too. Conservative; the user is explicitly opting in.
- **/reload**: `EC_session.startedAt` resets naturally (in-memory wipe). `bestGPH` and friends persist. The panel correctly shows "computing..." for 10s post-/reload, then the new session begins.
- **Per-character isolation**: `bestGPH` is in `PER_CHAR_FIELDS`, so each character has their own record. Switching characters does NOT carry the best forward.

## Test additions

### Test 68 (per-char migration carry)

In `tests/test_perf_guardrails.lua`, extend the Test 66 PER_CHAR_FIELDS list assertion to include the three new field names: `bestGPH`, `bestGPHAt`, `bestGPHZone`. A future contributor adding a new persistent stat must remember to add it to `PER_CHAR_FIELDS` or it leaks across characters; this test catches that for the three GPH fields specifically.

### Test 69 (5-minute gate)

In `tests/test_perf_guardrails.lua`, assert that `EbonClearance_MainPanel.lua` body contains:
- `elapsed >= 300` (the 5-minute gate)
- `EC_session.startedAt` or `NS.session.startedAt` (the session start reference)
- `DB.bestGPH` and `DB.bestGPHAt` and `DB.bestGPHZone` (the three fields updated together)

This locks the gate so a future refactor that drops the 5-minute filter or splits the three-field atomicity would fail in CI before shipping.

## Out of scope

Documented as deferred-not-rejected so future work has clear hooks:

- **Multi-player leaderboard**. Requires `SendAddonMessage` based inter-addon protocol. Limited to GUILD / PARTY / RAID / BATTLEGROUND / WHISPER channels (no global). A guild-scoped leaderboard is plausible scope for a future feature; would be its own spec + design. Filed as `future-feature/guild-leaderboard`.
- **Best-per-zone** (multiple records, one per zone the character has farmed in). Adds significant data shape complexity. The current spec keeps a single best record but tags it with the zone where it was achieved, which gives most of the value with one row of state.
- **Best-per-profession / class / role**. Same scope concern as best-per-zone.
- **GPH average / median over time**. Just current + best for now. YAGNI on aggregate analytics.
- **Tooltip on hover** showing additional detail on the Best Gold/Hour line. Could be added later if the user finds the inline context insufficient. Default: no tooltip; the second-line zone + when context is enough.
- **Export of best records** (e.g., as part of `/ec bugreport` or the v2.29.0 settings pack). Not added in this spec. Bug report could grow a "Best GPH: Xg in ZONE on DATE" line as a follow-up commit if useful.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| `GetTime()` resets across `/reload`. A user who runs an actual 6-hour farm session, /reload-s for any reason, opens stats - the session would show "computing..." with no carry-over. | This is the same behaviour the existing session stats already have (EC_session is in-memory). Accept the trade. The best record is what survives long-form farming, not the session line. |
| `time()` is wall-clock seconds; clock skew between client and server could produce mildly wrong durations on the "X days ago" calculation. | The display tolerance is "human-readable approximate". 5 minutes of skew on a "3 days ago" tag is invisible to the user. Accept. |
| Player who pulls a single huge lockbox loot for a quick 50g spike could trip the 5-minute gate if they hit it AT exactly the 5-minute mark. | The 5-minute gate is a soft heuristic, not a precise filter. A single legitimate big sell that lands just after 5:00 IS a legitimate best - if you sold 200g of gear over 5 minutes you genuinely farmed at that rate. Mitigation considered (require minimum N items sold), rejected as over-engineering. |
| `GetRealZoneText()` returns empty during the loading-screen transition between zones. Best update during a zone-transition window would capture "Unknown". | Acceptable. The session in question was a multi-zone farm and "Unknown" is an honest answer. The user can still see the rate + when. |
| The Best Gold/Hour line could mislead users who interpret it as "current best across all characters". | The line lives on the per-character Statistics block. Could add a "(this character)" parenthetical if user feedback warrants. Not in v1. |

## Implementation notes (for the plan)

- `EC_session.startedAt` initialisation: needs to happen in `EC_ResetSession()` AND at first `EnsureDB()` call (so a brand-new character or post-/reload session has a valid start). The existing `EC_ResetSession` is in `EbonClearance_Events.lua`; the function gets a single line added. The EnsureDB call site at PLAYER_LOGIN should call `EC_ResetSession()` once iff `startedAt == 0` to bootstrap.
- The display lines need new fontstring fields on the panel: `self.statsSessionGPH` and `self.statsBestGPH`. Created in `BuildMainPanel` next to the existing stat fontstrings; updated in `RefreshStats`.
- The session line should update LIVE while the panel is visible (the rate changes every second). Two options:
  1. Hook a 1-second timer (OnUpdate accumulator) while the panel is shown. Cheap; pattern already used elsewhere in the addon.
  2. Just refresh on panel show + after every merchant cycle. Simpler; users only see the value when they open `/ec` or after a sell. Live in-panel updates only when a merchant cycle completes.
- Recommend option 2 for v1 (simpler, no new OnUpdate hook). If users ask for live updates, option 1 is a trivial follow-up.
- Best-update fires inside `RefreshStats` so it happens whenever the panel renders. Panel renders on show + after merchant cycle. Good cadence; the user gets the update at natural checkpoints.

## Verification (in-game checklist for the implementation PR)

- [ ] Fresh `/reload`. Open `/ec` immediately. Session line shows "computing..." for ~10s, then begins ticking.
- [ ] After 10s with no sales, session line shows `0g 0s 0c` rate with elapsed time.
- [ ] Visit merchant, sell a single grey, immediately open `/ec`. Session line shows a high rate. Best line does NOT update (under 5 min).
- [ ] Run a sustained 5+ minute farm. Best line updates with current zone + "just now".
- [ ] /reload. Best line still shows the previous value with the relative time ("X minutes ago").
- [ ] Wait a day or two. "X minutes ago" rolls to "X hour(s) ago" then "X day(s) ago".
- [ ] After 30+ days, the relative time switches to `YYYY-MM-DD` format.
- [ ] Reset Lifetime button wipes bestGPH/At/Zone. Best line shows "-" again.
- [ ] Reset Session Stats button resets the live rate without touching the best.
- [ ] Switch to a different character. Best line shows that character's own record (or "-" if never set).
