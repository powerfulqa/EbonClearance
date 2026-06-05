# Empty-State Wording Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the missing empty-state messages to the editable lists (empty + no-search/filter-match) and reword the terse existing empty states (Stats, Process Bags) into one consistent, new-player-friendly tone.

**Architecture:** Inline per-surface (no shared widget). One new greyed FontString in `CreateListUI` shown when zero rows render; in-place string rewrites everywhere else.

**Tech Stack:** WoW 3.3.5a / Lua 5.1. No unit-test framework (the WoW API is not mockable) - verification is `luac -p` + the five static-pattern suites + in-game smoke, per project convention.

---

## Project conventions (read before starting)

- **Verify before committing.** Per the user's standing rule, do NOT commit until the change is confirmed in-game. Each task below runs local verification (`luac -p` + the five suites) but does NOT commit. A single commit + push + tag happens in the final task, AFTER the user's in-game smoke.
- Local verify command set (run from repo root):
  - `luac -p <file>.lua` for each touched file
  - `lua tests/test_layout_reactivity.lua && lua tests/test_perf_guardrails.lua && lua tests/test_comment_hygiene.lua && lua tests/test_comms_version.lua && lua tests/test_guildshare.lua`
- No em dashes (U+2014) anywhere. Player-facing text: brief, plain, lead with the state.

## File structure

- `EbonClearance_ListWidget.lua` - add the empty-state FontString + show/hide logic in `CreateListUI` / `Refresh`.
- `EbonClearance_MainPanel.lua` - reword the six `None yet` empty strings in `RefreshStats`.
- `EbonClearance_ProcessBagsPanel.lua` - reword the next-item "Nothing eligible." label.
- `CHANGELOG.md` - patch stanza (final task).

---

## Task 1: List widget empty state

**Files:**
- Modify: `EbonClearance_ListWidget.lua` (in `CreateListUI`, just after the `rowFactory` line; and in the `Refresh` tail)

- [ ] **Step 1: Create the empty-state FontString** (after `local rowFactory = EC_compCache.makeListRowFactory(content, setTableName)`)

Find:
```lua
    local rowFactory = EC_compCache.makeListRowFactory(content, setTableName)
```
Replace with:
```lua
    local rowFactory = EC_compCache.makeListRowFactory(content, setTableName)

    -- v2.41.3: empty-state line shown when Refresh renders zero rows - either
    -- the list has no items, or the search / rarity filter matched nothing.
    -- Two-point anchored so it tracks the reactive content width and wraps
    -- (no SetWidth snapshot); greyed via GameFontDisableSmall. Text + show/hide
    -- are set in Refresh.
    local emptyFS = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    emptyFS:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -8)
    emptyFS:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, -8)
    emptyFS:SetJustifyH("LEFT")
    emptyFS:SetJustifyV("TOP")
    if emptyFS.SetWordWrap then
        emptyFS:SetWordWrap(true)
    end
    emptyFS:Hide()
```

- [ ] **Step 2: Show/hide it in the Refresh tail**

Find:
```lua
        rowFactory.setActiveRows(shown)
        content:SetHeight(math.max(1, (shown * 22) + 8))
```
Replace with:
```lua
        rowFactory.setActiveRows(shown)
        if shown == 0 then
            -- #keys == 0 means the list itself is empty; otherwise items
            -- exist but the search / rarity filter hid them all.
            if #keys == 0 then
                emptyFS:SetText(
                    "This list is empty. Add an item by ID or name above, "
                        .. "or Alt+Right-Click an item in your bags."
                )
            else
                emptyFS:SetText("No items match your search.")
            end
            emptyFS:Show()
            content:SetHeight(44)
        else
            emptyFS:Hide()
            content:SetHeight(math.max(1, (shown * 22) + 8))
        end
```

- [ ] **Step 3: Verify**

Run: `luac -p EbonClearance_ListWidget.lua` -> expect no output (OK).
Run the five suites -> expect all `RESULT: all tests passed` (esp. `test_layout_reactivity`: the FontString is two-point anchored, no `SetWidth(w-N)`, so it stays green).

---

## Task 2: Reword the six Stats empty strings

**Files:**
- Modify: `EbonClearance_MainPanel.lua` (inside `RefreshStats`)

All six share the literal `"  |cff888888None yet|r"`, so each edit below includes unique surrounding context. Do them as six separate exact replacements.

- [ ] **Step 1: Sold by Quality**

Find:
```lua
        if not any then
            rows[#rows + 1] = "  |cff888888None yet|r"
        end
        panel.statsQualityBreakdown:SetText(table.concat(rows, "\n"))
```
Replace with:
```lua
        if not any then
            rows[#rows + 1] = "  |cff888888Nothing sold yet.|r"
        end
        panel.statsQualityBreakdown:SetText(table.concat(rows, "\n"))
```

- [ ] **Step 2: Deleted by Quality**

Find:
```lua
        if not any then
            rows[#rows + 1] = "  |cff888888None yet|r"
        end
        panel.statsDeletedByQuality:SetText(table.concat(rows, "\n"))
```
Replace with:
```lua
        if not any then
            rows[#rows + 1] = "  |cff888888Nothing deleted yet.|r"
        end
        panel.statsDeletedByQuality:SetText(table.concat(rows, "\n"))
```

- [ ] **Step 3: Top 5 Most Sold**

Find:
```lua
            panel.statsMostSold:SetText("|cffffd200Top 5 Most Sold|r\n  |cff888888None yet|r")
```
Replace with:
```lua
            panel.statsMostSold:SetText("|cffffd200Top 5 Most Sold|r\n  |cff888888Nothing sold yet.|r")
```

- [ ] **Step 4: Top 5 Most Deleted**

Find:
```lua
            panel.statsMostDeleted:SetText("|cffffd200Top 5 Most Deleted|r\n  |cff888888None yet|r")
```
Replace with:
```lua
            panel.statsMostDeleted:SetText("|cffffd200Top 5 Most Deleted|r\n  |cff888888Nothing deleted yet.|r")
```

- [ ] **Step 5: Process Bags Totals**

Find:
```lua
        if not any then
            rows[#rows + 1] = "  |cff888888None yet|r"
        end
        panel.statsProcessTotals:SetText(table.concat(rows, "\n"))
```
Replace with:
```lua
        if not any then
            rows[#rows + 1] = "  |cff888888Nothing processed yet.|r"
        end
        panel.statsProcessTotals:SetText(table.concat(rows, "\n"))
```

- [ ] **Step 6: Top Zones**

Find:
```lua
        local rows = { "|cffffd200Top Zones (gold earned)|r" }
        if #entries == 0 then
            rows[#rows + 1] = "  |cff888888None yet|r"
```
Replace with:
```lua
        local rows = { "|cffffd200Top Zones (gold earned)|r" }
        if #entries == 0 then
            rows[#rows + 1] = "  |cff888888No zones tracked yet.|r"
```

- [ ] **Step 7: Verify**

Run: `luac -p EbonClearance_MainPanel.lua` -> OK.
Run: `grep -n "None yet" EbonClearance_MainPanel.lua` -> expect no matches (all six reworded).
Run the five suites -> all pass.

---

## Task 3: Reword the Process Bags next-item label

**Files:**
- Modify: `EbonClearance_ProcessBagsPanel.lua`

- [ ] **Step 1: Replace the label text** ("eligible" is jargon)

Find:
```lua
            panel.nextItemLabel:SetText("|cffaaaaaaNothing eligible.|r")
```
Replace with:
```lua
            panel.nextItemLabel:SetText("|cffaaaaaaNothing to process right now.|r")
```

- [ ] **Step 2: Verify**

Run: `luac -p EbonClearance_ProcessBagsPanel.lua` -> OK.
Run the five suites -> all pass.

---

## Task 4: Docs, full verification, in-game smoke, ship

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the CHANGELOG stanza** (insert directly after the top `---` block, before `### v2.41.2`)

```markdown
### v2.41.3

Patch release. Clearer empty states across the UI.

- **The Sell / Account Sell / Keep / Delete lists now explain themselves when empty.** Previously an empty list (or a search/filter that matched nothing) showed a blank box. An empty list now reads "This list is empty. Add an item by ID or name above, or Alt+Right-Click an item in your bags."; a search or rarity filter that hides everything shows "No items match your search."
- **Stats empty states reworded** from the terse "None yet" to context-specific lines (Nothing sold yet. / Nothing deleted yet. / Nothing processed yet. / No zones tracked yet.).
- **Process Bags** now says "Nothing to process right now." instead of "Nothing eligible." (plainer wording).

Safe overwrite from v2.41.2. No schema changes.
```

- [ ] **Step 2: Full local verification**

Run: `luac -p EbonClearance_ListWidget.lua EbonClearance_MainPanel.lua EbonClearance_ProcessBagsPanel.lua` -> OK.
Run all five suites -> all `RESULT: all tests passed`.
Run the project's standard em-dash spot-check: grep the changed files for the U+2014 character -> expect no output, confirming none were introduced. (Referenced by codepoint name here so this plan file stays free of the literal character, per the repo rule.)

- [ ] **Step 3: Help-panel check**

Read the list-related FAQ entry ("What are the Sell, Keep, and Delete lists?" in `EbonClearance_HelpPanel.lua`). Confirm the new empty-state guidance does not contradict it (the FAQ already says you add by ID/name or Alt+Right-Click). No change expected; note if one is needed.

- [ ] **Step 4: Hand to user for in-game smoke (DO NOT commit before this)**

Ask the user to `/reload` and confirm:
- An empty Keep List shows the "This list is empty..." guidance.
- Typing a search that matches nothing shows "No items match your search."; adding/clearing flips it back.
- A fresh character's Stats shows "Nothing sold yet." etc.; Process Bags with nothing eligible shows "Nothing to process right now."

- [ ] **Step 5: Commit + push + tag (after in-game confirmation)**

```bash
git add EbonClearance_ListWidget.lua EbonClearance_MainPanel.lua EbonClearance_ProcessBagsPanel.lua CHANGELOG.md
git commit -m "fix: v2.41.3 - clearer empty states (list guidance + reworded Stats/Process)"
git push origin master
git tag v2.41.3 && git push origin v2.41.3
```
Then watch the Release workflow, and `git pull --rebase` to sync the version-bump bot commit (release-process step 9).

---

## Notes

- The `#keys` and `shown` locals already exist in `Refresh`; no new state is threaded.
- `emptyFS` lives in the scroll `content` (the ScrollChild), which resizes via the existing `box:SetScript("OnSizeChanged", ...)` hook, so the two-point anchor keeps it reactive without a `registerWidth` call.
- Do not blanket-replace `"  |cff888888None yet|r"` - the six occurrences need different contextual text (Task 2 does them individually).
