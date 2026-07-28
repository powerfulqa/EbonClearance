-- EbonClearance_StatsPanel - dedicated stats sub-panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Holds every stat widget (statsMoney, statsSold, statsDeleted, statsRepairs,
-- statsRepairCost, statsSessionGPH, statsBestGPH + zone/when sub-line,
-- statsAvgWorth, statsMostSold, statsNote, EbonClearanceResetStatsBtn).
-- These used to live on the Main panel; v2.36.x split them out so the Main
-- panel can read as a welcome page and Stats can grow.
--
-- RefreshStats (defined in EbonClearance_MainPanel.lua pre-split; re-homed
-- here post-split) writes to the panel.statsX attachments below. The
-- attachments are the public contract with the rest of the addon:
-- EbonClearance_Events.lua's data-change handlers call RefreshStats; this
-- file owns the panel object that holds the FontStrings.

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L

local StatsPanel = CreateFrame("Frame", "EbonClearanceOptionsStats", InterfaceOptionsFramePanelContainer)
StatsPanel.name = "Stats - Personal"
StatsPanel.parent = "EbonClearance"

-- v2.38.2: live refresh while the Stats panel is shown. RefreshStats
-- otherwise only fires on OnShow + after the GetItemInfo warmup, so the
-- panel goes static the moment the player opens it - they sell more
-- items, lifetime + session totals keep updating in memory, but the
-- displayed numbers stay frozen until the panel is closed and reopened.
-- v2.38.1's new "(session +N)" delta suffix made the static display
-- glaringly obvious because the suffix sits next to the lifetime total.
-- A 1Hz OnUpdate driver (cheap: one script call/sec, gated on visibility)
-- repaints while the panel is shown.
StatsPanel:SetScript("OnUpdate", function(self, elapsed)
    self._statsTickAcc = (self._statsTickAcc or 0) + elapsed
    if self._statsTickAcc >= 1.0 then
        self._statsTickAcc = 0
        -- v2.68.1: the tick routes through RefreshStatsTick, which
        -- full-repaints only when a rendered counter actually changed and
        -- otherwise refreshes just the time-varying Gold/Hour rows. The
        -- old unconditional NS.RefreshStats() rewrote ~40 FontStrings and
        -- re-anchored 6 section headers every second for nothing.
        if self:IsShown() then
            if NS.RefreshStatsTick then
                NS.RefreshStatsTick()
            elseif NS.RefreshStats then
                NS.RefreshStats()
            end
        end
    end
end)

StatsPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(refreshSelf)
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, function(buildSelf, content)
        -- Alias buildSelf as `panel` so the explicit panel.statsX = fs
        -- assignments below stay literal. The test suite scans for
        -- `panel.statsMoney`, `panel.statsSessionGPH`, `panel.statsBestGPH`
        -- as the public contract with RefreshStats - keep the literals.
        local panel = buildSelf
        -- Heading. Same -16 y offset as Keep List / Sell List etc.
        local heading = NS.MakeHeader(content, L["Stats - Personal"], -16)
        NS.AddHelpIcon(content, heading, "LEFT", "RIGHT", 8, 0, "stats-overview")

        -- v2.38.1: Character / Account view toggle. Sits between the
        -- heading and the first stat row. Two UIRadioButtonTemplate
        -- buttons + a one-line started-at note for the account ledger.
        -- _statsView is in-memory only - opens on Character view every
        -- time the panel shows.
        panel._statsView = panel._statsView or "character"

        local charRadio = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
        charRadio:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
        charRadio:SetChecked(panel._statsView == "character")
        local charLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        charLbl:SetPoint("LEFT", charRadio, "RIGHT", 4, 0)
        charLbl:SetText(L["Character"])

        local acctRadio = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
        acctRadio:SetPoint("LEFT", charLbl, "RIGHT", 16, 0)
        acctRadio:SetChecked(panel._statsView == "account")
        local acctLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        acctLbl:SetPoint("LEFT", acctRadio, "RIGHT", 4, 0)
        acctLbl:SetText(L["Account"])

        charRadio:SetScript("OnClick", function()
            panel._statsView = "character"
            charRadio:SetChecked(true)
            acctRadio:SetChecked(false)
            if NS.RefreshStats then
                NS.RefreshStats()
            end
            if panel._updateResetLabel then
                panel._updateResetLabel()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        acctRadio:SetScript("OnClick", function()
            panel._statsView = "account"
            charRadio:SetChecked(false)
            acctRadio:SetChecked(true)
            if NS.RefreshStats then
                NS.RefreshStats()
            end
            if panel._updateResetLabel then
                panel._updateResetLabel()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        -- Started-at note. Reads ADB.accountStats.startedAt and formats
        -- as a date string so the player understands the account ledger
        -- counts from v2.38.1 install, not from their full history.
        local startedAtNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        startedAtNote:SetPoint("TOPLEFT", charRadio, "BOTTOMLEFT", 0, -4)
        EC_compCache.setPanelWidth(startedAtNote, 16)
        startedAtNote:SetJustifyH("LEFT")
        if startedAtNote.SetWordWrap then
            startedAtNote:SetWordWrap(true)
        end
        local function refreshStartedAt()
            local ADB = NS.ADB
            local AS = ADB and ADB.accountStats
            local startedAt = AS and AS.startedAt or 0
            if startedAt > 0 then
                startedAtNote:SetText(
                    string.format(
                        L["|cff888888Account totals counting from %s. Per-character history pre-v2.38.1 stays on Character view.|r"],
                        date("%Y-%m-%d", startedAt)
                    )
                )
            else
                startedAtNote:SetText("")
            end
        end
        refreshStartedAt()
        panel._refreshStartedAt = refreshStartedAt

        -- Loot Log opener. Sits near the top (right under the view toggle)
        -- so it's easy to find rather than buried below the stat stack.
        -- Opens the standalone loot window (also reachable via /ec loot):
        -- what you've looted this session and the account-wide running
        -- total. Styled like the Main panel's Open Quickstart button.
        local lootBtn = CreateFrame("Button", "EbonClearanceOpenLootBtn", content, "UIPanelButtonTemplate")
        lootBtn:SetSize(140, 26)
        lootBtn:SetPoint("TOPLEFT", startedAtNote, "BOTTOMLEFT", 0, -10)
        lootBtn:SetText(L["Loot Log"])
        lootBtn:SetScript("OnClick", function()
            if NS.ToggleLootWindow then
                NS.ToggleLootWindow()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        local lootHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        lootHint:SetPoint("LEFT", lootBtn, "RIGHT", 10, 0)
        lootHint:SetJustifyH("LEFT")
        if lootHint.SetWordWrap then
            lootHint:SetWordWrap(true)
        end
        EC_compCache.setPanelWidth(lootHint, 180)
        lootHint:SetText(L["|cff888888What you've looted this session, or account-wide.|r"])

        -- Lifetime + session stats. Each panel.statsX is the contract
        -- with RefreshStats (called from EbonClearance_Events.lua's data
        -- handlers). Order matches the old MainPanel layout for visual
        -- continuity. The explicit panel.statsX = fs assignments below
        -- are the contract the test suite scans for - keep them literal
        -- (no table-driven indirection) so the static-pattern check can
        -- find them.
        -- v2.66.1 iter (Serv report): aggregate rows now use NS.MakeStatRow
        -- (row.left / row.right) so the value column aligns at a fixed X -
        -- matches Stats - Guild / Stats - Server. RefreshStats writes to
        -- row.left (label) and row.right (formatted value) instead of a
        -- single :SetText on the FontString.
        local AGGREGATE_VALUE_X = 200
        local function makeStatRow(yOffset, anchorPrev)
            return NS.MakeStatRow(content, anchorPrev, yOffset, AGGREGATE_VALUE_X)
        end

        -- v2.38.1: first stat row anchors below the started-at note now
        -- (was -44 from content TOPLEFT, which assumed the heading was
        -- the only thing above the stats).
        local money = makeStatRow(-16, lootBtn)
        panel.statsMoney = money
        local sold = makeStatRow(-6, money)
        panel.statsSold = sold
        local deleted = makeStatRow(-6, sold)
        panel.statsDeleted = deleted
        local repairs = makeStatRow(-6, deleted)
        panel.statsRepairs = repairs
        local repairCost = makeStatRow(-6, repairs)
        panel.statsRepairCost = repairCost
        local sessionGPH = makeStatRow(-6, repairCost)
        panel.statsSessionGPH = sessionGPH
        local bestGPH = makeStatRow(-6, sessionGPH)
        panel.statsBestGPH = bestGPH
        local avgWorth = makeStatRow(-6, bestGPH)
        panel.statsAvgWorth = avgWorth
        -- v2.66.1 iter (Serv report): Sold-by-Quality now header + per-
        -- quality MakeStatRow so the value column aligns at TOP5_VALUE_X
        -- (same X used by Top 5 lists below). RefreshStats writes to
        -- row.left / row.right per quality bucket instead of a single
        -- table.concat FontString.
        local qualityBreakdown = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        qualityBreakdown:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(qualityBreakdown, 16)
        qualityBreakdown:SetJustifyH("LEFT")
        qualityBreakdown:SetJustifyV("TOP")
        -- Also declare the row containers here so the anchor chain below
        -- can descend past all 8 possible rows. Quality indices 0..7.
        -- v2.66.1 iter 2 (Serv report): third column for Sold-by-Quality's
        -- gold value. row.left = quality name, row.right = count, row.gold
        -- = gold value at a fixed X column so the "Xg" values stack.
        -- v2.66.1 iter 2 (Serv report): gold column moved closer to the
        -- count column (was 320 - too far right). 260 keeps them visually
        -- as a pair while still stacking to a fixed X across rows.
        local SOLD_GOLD_X = 260
        panel._soldByQualityRows = {}
        local lastSoldQ = qualityBreakdown
        for q = 0, 7 do
            local row = NS.MakeStatRow(content, lastSoldQ, q == 0 and -2 or 0, 200)
            row.gold = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            row.gold:SetPoint("LEFT", row, "LEFT", SOLD_GOLD_X, 0)
            row.gold:SetJustifyH("LEFT")
            panel._soldByQualityRows[q] = row
            lastSoldQ = row
        end
        panel._soldByQualityEmpty = NS.MakeStatRow(content, qualityBreakdown, -2, 200)
        if qualityBreakdown.SetWordWrap then
            qualityBreakdown:SetWordWrap(true)
        end
        panel.statsQualityBreakdown = qualityBreakdown
        -- v2.37.x: "Deleted by Quality" mirrors "Sold by Quality" -
        -- per-rarity counts only (no copper, deletion produces no
        -- money). Rendered when DB.deletedItemsByQuality has any
        -- non-zero entry; reads "None yet" otherwise.
        -- v2.66.1 iter: anchor descends past all 8 Sold-by-Quality rows.
        -- Deleted-by-Quality itself becomes header + per-quality rows too.
        local deletedByQuality = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        deletedByQuality:SetPoint("TOPLEFT", lastSoldQ, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(deletedByQuality, 16)
        deletedByQuality:SetJustifyH("LEFT")
        deletedByQuality:SetJustifyV("TOP")
        panel.statsDeletedByQuality = deletedByQuality
        panel._deletedByQualityRows = {}
        local lastDelQ = deletedByQuality
        for q = 0, 7 do
            local row = NS.MakeStatRow(content, lastDelQ, q == 0 and -2 or 0, 200)
            panel._deletedByQualityRows[q] = row
            lastDelQ = row
        end
        panel._deletedByQualityEmpty = NS.MakeStatRow(content, deletedByQuality, -2, 200)
        -- v2.66.1 iter (Serv report): Top 5 lists converted from a single
        -- FontString (with newline-joined rows) to a header + per-row
        -- MakeStatRow containers so the count column aligns at a fixed
        -- X - matches the spreadsheet-style alignment on Stats - Guild
        -- and Stats - Server. RefreshStats writes to row.left (rank +
        -- item name) and row.right (count) instead of a table.concat.
        local TOP5_VALUE_X = 200
        local function makeTopRow(anchor, yOff)
            return NS.MakeStatRow(content, anchor, yOff, TOP5_VALUE_X)
        end
        -- Header FontString (unchanged in shape from v2.37.0).
        local mostSoldHeader = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        -- v2.66.1 iter: descend past all 8 Deleted-by-Quality rows.
        mostSoldHeader:SetPoint("TOPLEFT", lastDelQ, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(mostSoldHeader, 16)
        mostSoldHeader:SetJustifyH("LEFT")
        panel.statsMostSold = mostSoldHeader
        panel._mostSoldHeader = mostSoldHeader
        panel._mostSoldRows = {}
        local lastMostSoldAnchor = mostSoldHeader
        for i = 1, 5 do
            local row = makeTopRow(lastMostSoldAnchor, i == 1 and -2 or 0)
            panel._mostSoldRows[i] = row
            lastMostSoldAnchor = row
        end
        panel._mostSoldEmpty = makeTopRow(mostSoldHeader, -2)

        -- Top 5 Most Deleted mirrors Top 5 Most Sold.
        local mostDeletedHeader = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        mostDeletedHeader:SetPoint("TOPLEFT", lastMostSoldAnchor, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(mostDeletedHeader, 16)
        mostDeletedHeader:SetJustifyH("LEFT")
        panel.statsMostDeleted = mostDeletedHeader
        panel._mostDeletedHeader = mostDeletedHeader
        panel._mostDeletedRows = {}
        local lastMostDeletedAnchor = mostDeletedHeader
        for i = 1, 5 do
            local row = makeTopRow(lastMostDeletedAnchor, i == 1 and -2 or 0)
            panel._mostDeletedRows[i] = row
            lastMostDeletedAnchor = row
        end
        panel._mostDeletedEmpty = makeTopRow(mostDeletedHeader, -2)

        -- v2.66.1 iter 4 (Serv report): Process Bags Totals converted from
        -- a single multi-line FontString to a header + per-operation
        -- MakeStatRow rig so the count column aligns at TOP5_VALUE_X -
        -- matches the spreadsheet-style alignment elsewhere on the panel.
        -- RefreshStats writes to row.left (operation label) and row.right
        -- (count) instead of table.concat.
        local processTotals = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        processTotals:SetPoint("TOPLEFT", lastMostDeletedAnchor, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(processTotals, 16)
        processTotals:SetJustifyH("LEFT")
        processTotals:SetJustifyV("TOP")
        panel.statsProcessTotals = processTotals
        panel._processRows = {}
        local lastProcess = processTotals
        for i = 1, 4 do
            local row = makeTopRow(lastProcess, i == 1 and -2 or 0)
            panel._processRows[i] = row
            lastProcess = row
        end
        -- (v2.68.1: the old panel._processEmpty "Nothing processed yet" row
        -- was removed - all four process rows always render since v2.66.1,
        -- so the empty-state could never show.)

        -- v2.66.1 iter: Top zones header + per-zone MakeStatRow so the
        -- gold column aligns at TOP5_VALUE_X.
        local topZones = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        topZones:SetPoint("TOPLEFT", lastProcess, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(topZones, 16)
        topZones:SetJustifyH("LEFT")
        topZones:SetJustifyV("TOP")
        panel.statsTopZones = topZones
        panel._topZoneRows = {}
        local lastZone = topZones
        for i = 1, 5 do
            local row = NS.MakeStatRow(content, lastZone, i == 1 and -2 or 0, 200)
            panel._topZoneRows[i] = row
            lastZone = row
        end
        panel._topZoneEmpty = NS.MakeStatRow(content, topZones, -2, 200)

        -- Footnote about buyback exclusion.
        local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        -- v2.66.1 iter: descend past all 5 Top-Zones rows.
        statsNote:SetPoint("TOPLEFT", lastZone, "BOTTOMLEFT", 0, -4)
        EC_compCache.setPanelWidth(statsNote, 16)
        statsNote:SetJustifyH("LEFT")
        statsNote:SetText(L["|cff888888Stats don't account for items bought back from a merchant.|r"])
        panel.statsNote = statsNote

        -- Reset Session button. Clears the in-memory session deltas (the
        -- "session +X" suffixes next to each stat) without touching the
        -- lifetime totals. NS.ResetSession lives in EbonClearance_Events.lua.
        local resetSessionBtn = CreateFrame("Button", "EbonClearanceResetSessionBtn", content, "UIPanelButtonTemplate")
        resetSessionBtn:SetSize(170, 22)
        resetSessionBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -10)
        resetSessionBtn:SetText(L["Reset Session Stats"])
        resetSessionBtn:SetScript("OnClick", function()
            if NS.ResetSession then
                NS.ResetSession()
            end
            if NS.RefreshStats then
                NS.RefreshStats()
            end
        end)

        -- Reset Lifetime button. v2.38.1: branches on the active view -
        -- Character view clears this character's DB.* lifetime; Account
        -- view clears the ADB.accountStats.* aggregate. NS.ResetLifetimeStats
        -- reads panel._statsView to decide which side to wipe. The button
        -- label adapts so the player knows what they're about to nuke.
        local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", content, "UIPanelButtonTemplate")
        resetBtn:SetSize(220, 22)
        resetBtn:SetPoint("LEFT", resetSessionBtn, "RIGHT", 8, 0)
        local function updateResetLabel()
            if panel._statsView == "account" then
                resetBtn:SetText(L["Reset Lifetime (account)"])
            else
                resetBtn:SetText(L["Reset Lifetime (this character)"])
            end
        end
        updateResetLabel()
        panel._updateResetLabel = updateResetLabel
        resetBtn:SetScript("OnClick", function()
            local dialog = StaticPopup_Show("EC_CONFIRM_RESET_LIFETIME")
            if dialog then
                dialog.data = function()
                    if NS.ResetLifetimeStats then
                        NS.ResetLifetimeStats()
                    end
                    if NS.RefreshStats then
                        NS.RefreshStats()
                    end
                    -- Account-view reset stamps a new startedAt; refresh
                    -- the date line so the player sees the new "counting
                    -- from <today>" immediately.
                    if panel._refreshStartedAt then
                        panel._refreshStartedAt()
                    end
                end
            end
        end)

        if NS.RefreshStats then
            NS.RefreshStats()
        end
        -- v2.37.x: size the scroll content frame to fit the bottom-most
        -- widget so the panel scrolls when the stack grows past the
        -- Interface Options container's natural height. resetBtn is the
        -- last widget; FitScrollContent measures its bottom edge against
        -- the content frame's TOPLEFT. Same pattern as the Main /
        -- Scavenger / Merchant / Item Highlighting panels.
        if NS.FitScrollContent then
            NS.FitScrollContent(content, resetBtn)
        end
    end, true)
end)

-- v2.36.x: registered with InterfaceOptions_AddCategory from
-- EbonClearance_Events.lua (right after the Main panel) so the sub-panel
-- sort order (Main / Stats / Merchant / ...) is controlled at one place.

-- ============================================================
-- Session Loot window
-- ============================================================
-- Standalone floating window opened by the Stats panel's "Session Loot"
-- button and by /ec loot. Read-only scroll list of items looted showing
-- count, vendor value and each item's share of the total, in three scopes:
-- Session (NS.lootSession, in-memory, clears on /reload or Reset Session),
-- Character (DB.lootedItemCounts) and Account (the persisted account-wide
-- running total). Narrowed by a rarity dropdown and a free-text search.
-- Resizable via the bottom-right grip, but it never snapshots
-- EC_PANEL_WIDTH - the scroll child tracks the viewport through the
-- scroll frame's own OnSizeChanged, so this window stays outside the
-- reactive-width contract that governs the Interface Options sub-panels.
-- Loot capture + storage live in EbonClearance_Events.lua.
local lootWindow

local LOOT_ROW_H = 18
-- v2.68.0: per-itemID cache-priming attempt counter. Session-only, and
-- deliberately NOT saved: the client's item cache persists to disk, so a
-- later session usually resolves these on the first GetItemInfo with no
-- priming at all. The cap stops a handful of itemIDs that never resolve
-- (removed from the game DB, or a server that will not serve them) from
-- re-priming on every single refresh forever, which would also pin the
-- loot window on its fast refresh cadence permanently.
local lootPrimeTries = {}
local LOOT_PRIME_MAX_TRIES = 3

-- v2.68.0 (Serv report): coin text with a comma-grouped gold figure.
-- GetCoinTextureString emits the gold amount raw, and a seven-digit
-- total ("1037251g") is unreadable at a glance.
--
-- EC-TRAP: only the LEADING digit run is substituted, and only once. The
-- rest of the returned string is texture escapes
-- (|TInterface\MoneyFrame\UI-GoldIcon:12:12:2:0|t) which contain digits
-- of their own - a global %d substitution corrupts the coin icons.
-- When gold is 0 the string starts with the silver figure instead, which
-- is at most two digits, so commaing it is a harmless no-op.
local function lootCoinText(copper, fallback)
    if not (copper and copper > 0 and GetCoinTextureString) then
        return fallback
    end
    local s = GetCoinTextureString(copper)
    return (s:gsub("^(%d+)", function(g)
        return NS.CommaNumber(tonumber(g) or 0)
    end, 1))
end
local LOOT_DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Forward-declared so the row factory's right-click handler (defined before
-- the body below) can call it as an upvalue. Assigned with `function
-- lootRefresh(win)` further down, NOT `local function`, so it stays the same
-- upvalue everything here captures.
local lootRefresh

-- Build a sorted array of { id, qty, value, name, quality, texture } for the
-- given scope, narrowed by rarityFilter and/or search when set, plus the
-- totals of quantity AND vendor value.
--
-- v2.68.0 (Serv request): the totals cover ONLY the rows that survive the
-- filters. They used to span every entry in the scope, so with a filter on,
-- the per-row percentages read as a share of everything ever looted and the
-- visible rows summed to some small fraction of 100%. Now filtering to Epics
-- gives you each Epic's share OF YOUR EPICS, and the shares of what is on
-- screen add up to 100%. The header counts rebase the same way, so the whole
-- window consistently describes the current view rather than mixing the two.
--
-- value = per-unit vendor sell price (GetItemInfo) x quantity; it's 0 for
-- items with no sell price, which is itself useful - it flags the worthless
-- drops worth deleting. One GetItemInfo per item (cached) feeds sort + render.
-- Returns (arr, total, totalValue, primed); `primed` is how many item-cache
-- fetches this pass kicked off, which drives the window's refresh cadence.
local function lootBuildArray(scope, sortKey, sortDir, rarityFilter, search)
    local src
    if scope == "account" then
        local AS = NS.ADB and NS.ADB.accountStats
        src = AS and AS.lootedItemCounts
    elseif scope == "character" then
        src = NS.DB and NS.DB.lootedItemCounts
    else
        src = NS.lootSession
    end
    -- Hidden items (right-clicked to hide) are dropped before the totals, so
    -- the remaining rows' count/gold shares rebase as if the hidden ones were
    -- never looted. As of v2.68.0 the rarity + search filters behave the same
    -- way, so all three narrowing mechanisms are consistent: whatever is out
    -- of view is out of the totals.
    local hidden = (NS.ADB and NS.ADB.lootLogHidden) or {}
    local arr, total, totalValue = {}, 0, 0
    -- v2.68.0 (Serv report): the account scope aggregates loot from every
    -- character, so it names items THIS character has never seen. Those
    -- are absent from the client's item cache, GetItemInfo returns nil
    -- for all of them, and the row rendered as "item:3669" with a "?"
    -- icon. Less visibly it also contributed 0 to the gold column and
    -- was invisible to any rarity filter, because sellPrice and quality
    -- were nil too.
    --
    -- Prime the cache the same way EbonClearance_BugReport.lua does: a
    -- SetHyperlink on the hidden scan tooltip makes the client fetch the
    -- item, and the retry picks it up when the fetch resolved on this
    -- frame. Bounded per pass - an account log with thousands of
    -- uncached items would otherwise fire thousands of fetches in one
    -- frame. Anything left unresolved fills in on a later pass: the
    -- window's own 2 s safety refresh re-renders, so the rows populate
    -- themselves with no extra timer.
    local primesLeft = 25
    local primed = 0
    local needle = (search and search ~= "") and search:lower() or nil
    if src then
        for itemID, qty in pairs(src) do
            if qty and qty > 0 and not hidden[itemID] then
                local name, _, q, _, _, _, _, _, _, texture, sellPrice = GetItemInfo(itemID)
                local tries = lootPrimeTries[itemID] or 0
                if not name and primesLeft > 0 and tries < LOOT_PRIME_MAX_TRIES then
                    primesLeft = primesLeft - 1
                    lootPrimeTries[itemID] = tries + 1
                    primed = primed + 1
                    local st = NS.scanTooltip
                    if st and st.SetHyperlink then
                        pcall(st.SetOwner, st, UIParent, "ANCHOR_NONE")
                        pcall(st.ClearLines, st)
                        pcall(st.SetHyperlink, st, "item:" .. itemID)
                        name, _, q, _, _, _, _, _, _, texture, sellPrice = GetItemInfo(itemID)
                    end
                end
                local value = (sellPrice or 0) * qty
                -- v2.68.0 (Serv request): free-text name filter, matching the
                -- Sold History window's search box. Matched against the
                -- DISPLAYED name so an uncached "item:3669" row is still
                -- findable while its name resolves.
                local displayName = name or ("item:" .. itemID)
                local matchesSearch = true
                if needle then
                    matchesSearch = displayName:lower():find(needle, 1, true) ~= nil
                end
                if (rarityFilter == nil or q == rarityFilter) and matchesSearch then
                    -- Totals accumulate INSIDE the filter test, so they cover
                    -- only what is on screen (see the note on this function).
                    -- Moving these two lines back out silently reverts the
                    -- percentages to a share-of-everything reading.
                    total = total + qty
                    totalValue = totalValue + value
                    arr[#arr + 1] = {
                        id = itemID,
                        qty = qty,
                        value = value,
                        name = displayName,
                        quality = q,
                        texture = texture,
                    }
                end
            end
        end
    end
    -- sortDir: 1 = ascending, -1 = descending. Ties break on itemID for a
    -- stable order. "count" sorts by quantity, "gold" by vendor value (these
    -- diverge when prices differ - the whole point of the gold column), and
    -- "name" alphabetically.
    sortDir = sortDir or -1
    local function byField(field)
        return function(a, b)
            if a[field] ~= b[field] then
                if sortDir == 1 then
                    return a[field] < b[field]
                end
                return a[field] > b[field]
            end
            return a.id < b.id
        end
    end
    if sortKey == "name" then
        table.sort(arr, function(a, b)
            if a.name ~= b.name then
                if sortDir == 1 then
                    return a.name < b.name
                end
                return a.name > b.name
            end
            return a.id < b.id
        end)
    elseif sortKey == "gold" then
        table.sort(arr, byField("value"))
    else
        table.sort(arr, byField("qty"))
    end
    -- `primed` tells the caller whether names are still resolving, which
    -- picks the window's refresh cadence (see the OnUpdate driver).
    return arr, total, totalValue, primed
end

-- Pooled row factory. Rows anchor to content's TOPLEFT/TOPRIGHT so they
-- stretch with the (fixed) content width; reused across Refresh calls.
-- v2.68.0: `i` is now the POOL slot, not the data index, and the row is
-- positioned by lootRenderVisible at bind time rather than here. The
-- pool holds only enough rows to cover the viewport (see the note on
-- lootRenderVisible); a given slot shows a different item as you scroll.
local function lootGetRow(win, i)
    win.rows = win.rows or {}
    local row = win.rows[i]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, win.content)
    row:SetHeight(LOOT_ROW_H)
    -- Alt+hover shows the item's tooltip, which EbonClearance's tooltip hook
    -- annotates with the SAME plain-English verdict + reason you see hovering
    -- the item in your bags ("Keep (Green, no item level)", "Won't Sell (no
    -- value)", "Will Sell (junk)", etc.) - the humanised read, NOT the
    -- technical /ec sellinfo step trace. We hover the live bag item when it's
    -- still in bags (most precise) and fall back to a generic item tooltip
    -- otherwise, noting it's no longer in bags. Plain hover does nothing, so
    -- the list stays quiet unless the player asks.
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not IsAltKeyDown() or not self.itemID then
            return
        end
        local id = self.itemID
        local foundBag, foundSlot
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                if GetContainerItemID(bag, slot) == id then
                    foundBag, foundSlot = bag, slot
                    break
                end
            end
            if foundBag then
                break
            end
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if foundBag then
            -- SetBagItem fires the tooltip hook, which appends EC's verdict
            -- line with its reason - exactly the bag-hover annotation.
            GameTooltip:SetBagItem(foundBag, foundSlot)
        else
            GameTooltip:SetHyperlink("item:" .. id)
            GameTooltip:AddLine(L["|cff888888Not in your bags now - hover it in your bags for the live read.|r"], 1, 1, 1, true)
        end
        GameTooltip:AddLine(L["|cff808080Right-click to hide from the Loot Log.|r"], 1, 1, 1, true)
        GameTooltip:Show()
        -- This window is TOOLTIP strata, so the tooltip renders behind it
        -- without an absolute level stamp. See the EC-TRAP note on the
        -- helper in EbonClearance_PanelWidgets.lua.
        NS.RaiseTooltipAboveWindows()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    -- Right-click hides this item from the Loot Log. Hidden items drop out
    -- of the list AND the totals, so every other row's count/gold share
    -- rebases. Restore them all with the window's "Unhide All" button.
    row:SetScript("OnMouseUp", function(self, button)
        if button ~= "RightButton" or not self.itemID then
            return
        end
        if NS.ADB then
            NS.ADB.lootLogHidden = NS.ADB.lootLogHidden or {}
            NS.ADB.lootLogHidden[self.itemID] = true
        end
        lootRefresh(win)
        if NS.PrintNicef then
            local n = (GetItemInfo(self.itemID)) or ("item:" .. self.itemID)
            NS.PrintNicef(L["Hid %s from the Loot Log. Use Unhide All to bring it back."], n)
        end
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.icon = icon
    -- Right-aligned amount column ("xN  P%"). Anchored to the row's right so
    -- the count + share stay visible; the name column truncates on the left
    -- instead of pushing the numbers off-screen.
    local amount = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    amount:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    amount:SetJustifyH("RIGHT")
    row.amount = amount
    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    label:SetPoint("RIGHT", amount, "LEFT", -6, 0)
    label:SetJustifyH("LEFT")
    row.label = label
    win.rows[i] = row
    return row
end

-- v2.68.0 (Serv report: account scope slowed the WHOLE game, not just
-- this window): render ONLY the rows currently in the viewport.
--
-- Before this, lootRefresh created a frame per entry - with 5000+ items
-- in the Character / Account scopes that is 5000 frames, each carrying
-- an icon texture and two FontStrings, so ~20000 live UI objects. WoW's
-- layout cost scales with live frame count across the whole UI, which is
-- why the slowdown was global rather than confined to the list, and why
-- scrolling (which re-lays-out the scroll child) made it worst.
--
-- Now the pool holds only what fits the viewport plus a small buffer
-- (~20 rows), and scrolling re-binds those same frames to a different
-- slice of the array. Frame count is constant regardless of list size,
-- so Account scope costs the same as Session. The scrollbar range still
-- reflects the full list because content height is still #arr rows.
--
-- EC-TRAP: rows are positioned HERE, per bind, not in lootGetRow. The
-- pool index is a screen slot, NOT the data index - do not "simplify"
-- by anchoring rows once at creation, that is what this replaced.
local function lootRenderVisible(win)
    if not win or not win.content then
        return
    end
    local arr = win._arr or {}
    local totalValue = win._totalValue or 0
    local scroll = win.scroll
    local viewH = (scroll and scroll:GetHeight()) or 0
    local offset = (scroll and scroll:GetVerticalScroll()) or 0
    -- Index of the first row intersecting the top of the viewport.
    local first = math.floor(offset / LOOT_ROW_H)
    if first < 0 then
        first = 0
    end
    -- +2 covers the partially-visible rows at each edge.
    local slots = math.ceil(viewH / LOOT_ROW_H) + 2
    for j = 1, slots do
        local idx = first + j
        local e = arr[idx]
        local row = lootGetRow(win, j)
        if e then
            local y = -(idx - 1) * LOOT_ROW_H
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, y)
            row:SetPoint("TOPRIGHT", win.content, "TOPRIGHT", 0, y)
            row.itemID = e.id
            local hex = "ffffffff"
            if
                e.quality
                and ITEM_QUALITY_COLORS
                and ITEM_QUALITY_COLORS[e.quality]
                and ITEM_QUALITY_COLORS[e.quality].hex
            then
                hex = ITEM_QUALITY_COLORS[e.quality].hex:gsub("|c", "")
            end
            row.icon:SetTexture(e.texture or LOOT_DEFAULT_ICON)
            row.label:SetText(string.format("|c%s%s|r", hex, e.name))
            -- Amount column: count, vendor value, and that value's share of
            -- the gold total for the CURRENT view (v2.68.0) - so with a
            -- filter on the shares are relative to what you filtered to, and
            -- the visible rows add up to 100%. A worthless drop shows a grey
            -- dash + 0%, the cue to filter/delete.
            local goldPct = (totalValue > 0) and (e.value / totalValue * 100) or 0
            local coin = lootCoinText(e.value, "|cff707070-|r")
            -- v2.68.0 (Serv report): two decimals, not one. With thousands of
            -- distinct drops every share is under ~1.5%, so at one decimal
            -- whole runs of rows all read "0.8%" and the column stopped
            -- ranking anything. The second decimal separates them again.
            row.amount:SetText(
                string.format("|cff808080x%s|r  %s  |cff888888%.2f%%|r", NS.CommaNumber(e.qty), coin, goldPct)
            )
            row:Show()
        else
            row.itemID = nil
            row:Hide()
        end
    end
    -- Slots beyond what the current viewport needs (window was shrunk).
    if win.rows then
        for j = slots + 1, #win.rows do
            win.rows[j]:Hide()
        end
    end
end
function lootRefresh(win)
    if not win then
        return
    end
    local arr, total, totalValue, primed =
        lootBuildArray(win.scope or "session", win.sortKey, win.sortDir, win.rarityFilter, win.search)
    -- Stashed for lootRenderVisible, which re-binds the pooled rows on
    -- every scroll WITHOUT rebuilding or re-sorting the array.
    win._arr = arr
    win._totalValue = totalValue
    win._primedLast = primed or 0
    win.content:SetHeight(math.max(1, #arr * LOOT_ROW_H))
    lootRenderVisible(win)
    -- Reflect the hidden-item count on the Unhide All button, and grey it out
    -- when nothing is hidden.
    if win.unhideBtn then
        local nHidden = 0
        local h = NS.ADB and NS.ADB.lootLogHidden
        if h then
            for _ in pairs(h) do
                nHidden = nHidden + 1
            end
        end
        if nHidden > 0 then
            win.unhideBtn:SetText(string.format(L["Unhide All (%d)"], nHidden))
            win.unhideBtn:Enable()
        else
            win.unhideBtn:SetText(L["Unhide All"])
            win.unhideBtn:Disable()
        end
    end
    if win.totalLine then
        if #arr == 0 then
            win.totalLine:SetText(L["|cff888888Nothing looted yet.|r"])
        else
            local coinTotal = lootCoinText(totalValue, "0")
            win.totalLine:SetText(
                string.format(L["%s items  |  %s looted  |  %s"], NS.CommaNumber(#arr), NS.CommaNumber(total), coinTotal)
            )
        end
    end
end

local function lootEnsureWindow()
    if lootWindow then
        return lootWindow
    end
    local win = CreateFrame("Frame", "EbonClearanceLootWindow", UIParent)
    -- v2.66.1 (Serv report): TOOLTIP strata (not FULLSCREEN_DIALOG) so
    -- the loot log sits above the Interface Options frame. Same reason
    -- the Quickstart panel + Sold History window use TOOLTIP.
    win:SetFrameStrata("TOOLTIP")
    win:SetSize(360, 440)
    win:SetPoint("CENTER")
    win:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetResizable(true)
    if win.SetMinResize then
        win:SetMinResize(300, 260)
    end
    if win.SetMaxResize then
        win:SetMaxResize(700, 820)
    end
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:Hide()
    win.scope = "session"
    win.sortKey = "gold" -- "name" | "count" | "gold"
    win.sortDir = -1 -- 1 ascending, -1 descending (highest-earning first by default)
    win.rarityFilter = nil -- nil = all; otherwise a quality number 0-4
    win.search = "" -- free-text name filter; "" = no filter

    local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("|cff66ccffEbonClearance|r: " .. L["Loot Log"])

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    -- Scope radios: Session (this login, in-memory) / Character (this
    -- character's lifetime) / Account (all characters combined). A single
    -- setScope helper keeps exactly one checked and re-renders.
    local scopeRadios = {}
    local function setScope(scope)
        win.scope = scope
        for k, r in pairs(scopeRadios) do
            r:SetChecked(k == scope)
        end
        lootRefresh(win)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
    local function makeScopeRadio(scope, labelText, anchorTo)
        local r = CreateFrame("CheckButton", nil, win, "UIRadioButtonTemplate")
        if anchorTo then
            r:SetPoint("LEFT", anchorTo, "RIGHT", 14, 0)
        else
            r:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
        end
        local lbl = win:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        lbl:SetPoint("LEFT", r, "RIGHT", 4, 0)
        lbl:SetText(labelText)
        r:SetScript("OnClick", function()
            setScope(scope)
        end)
        scopeRadios[scope] = r
        return lbl
    end
    local sessLbl = makeScopeRadio("session", L["Session"], nil)
    local charLbl = makeScopeRadio("character", L["Character"], sessLbl)
    makeScopeRadio("account", L["Account"], charLbl)
    scopeRadios.session:SetChecked(true)

    -- Total line (under the radios).
    local totalLine = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    totalLine:SetPoint("TOPLEFT", scopeRadios.session, "BOTTOMLEFT", 0, -8)
    totalLine:SetJustifyH("LEFT")
    win.totalLine = totalLine

    -- Clear button. Wipes only the currently-viewed scope.
    local clearBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    clearBtn:SetSize(90, 20)
    clearBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -54)
    clearBtn:SetText(L["Clear"])
    clearBtn:SetScript("OnClick", function()
        if NS.ClearLoot then
            NS.ClearLoot(win.scope)
        end
        lootRefresh(win)
    end)

    -- Sort controls. Name / Count / Gold each toggle ascending <-> descending
    -- on repeat clicks; the active column shows a direction caret. Count sorts
    -- by quantity looted, Gold by vendor value (qty x sell price) - these
    -- diverge when prices differ, which is the whole point of the gold view.
    local sortLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sortLabel:SetPoint("TOPLEFT", totalLine, "BOTTOMLEFT", 0, -8)
    sortLabel:SetText(L["Sort:"])

    local sortBtns = {}
    local function updateSortButtons()
        local function caret(key)
            if win.sortKey ~= key then
                return ""
            end
            return win.sortDir == 1 and " |cffffd200^|r" or " |cffffd200v|r"
        end
        sortBtns.name:SetText(L["Name"] .. caret("name"))
        sortBtns.count:SetText(L["Count"] .. caret("count"))
        sortBtns.gold:SetText(L["Gold"] .. caret("gold"))
    end
    local function setSort(key)
        if win.sortKey == key then
            win.sortDir = -win.sortDir
        else
            win.sortKey = key
            -- Names read best A-Z; amounts read best most-first.
            win.sortDir = (key == "name") and 1 or -1
        end
        updateSortButtons()
        lootRefresh(win)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
    local function makeSortBtn(key, w, anchorTo)
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(w, 18)
        b:SetPoint("LEFT", anchorTo, "RIGHT", 6, 0)
        b:SetScript("OnClick", function()
            setSort(key)
        end)
        return b
    end
    sortBtns.name = makeSortBtn("name", 64, sortLabel)
    sortBtns.count = makeSortBtn("count", 60, sortBtns.name)
    sortBtns.gold = makeSortBtn("gold", 56, sortBtns.count)
    updateSortButtons()

    -- Rarity filter. "All rarities" plus one entry per quality; restricts
    -- which rows show. As of v2.68.0 the header counts and the per-row
    -- percentages rebase onto the filtered set, so filtering to Epics gives
    -- each Epic's share of your Epics and the visible rows sum to 100%.
    local rarityLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rarityLabel:SetPoint("TOPLEFT", sortLabel, "BOTTOMLEFT", 0, -14)
    rarityLabel:SetText(L["Show:"])
    -- v2.68.0 (Serv report): built through NS.MakeRarityDropdown, shared
    -- with the Sold History window. The helper also installs the
    -- TOOLTIP-strata fix without which this flyout opens BEHIND the
    -- window (see the EC-TRAP note in EbonClearance_PanelWidgets.lua) -
    -- do not rebuild this dropdown inline.
    local rarityDD = NS.MakeRarityDropdown(win, "EbonClearanceLootRarityDD", function(q)
        win.rarityFilter = q
        lootRefresh(win)
    end)
    rarityDD:SetPoint("LEFT", rarityLabel, "RIGHT", -6, -2)

    -- Unhide All button, on the rarity row. Right-clicking a row hides that
    -- item (it drops from the list and the totals); this restores every
    -- hidden item. Label carries the hidden count; disabled when none hidden.
    -- The hidden set is account-wide (ADB.lootLogHidden), so it applies to all
    -- three scope views.
    local unhideBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    unhideBtn:SetSize(110, 20)
    unhideBtn:SetPoint("LEFT", rarityDD, "RIGHT", 8, 2)
    unhideBtn:SetText(L["Unhide All"])
    unhideBtn:SetScript("OnClick", function()
        if NS.ADB and NS.ADB.lootLogHidden then
            for k in pairs(NS.ADB.lootLogHidden) do
                NS.ADB.lootLogHidden[k] = nil
            end
        end
        lootRefresh(win)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    win.unhideBtn = unhideBtn

    -- v2.68.0 (Serv request): free-text filter. With thousands of rows in
    -- the Character / Account scopes, scrolling to one item is hopeless;
    -- this narrows by name the way the Sold History window's search box
    -- does. Combines with the rarity dropdown and the scope radios.
    -- Own row: the window is only 360 px wide (300 min), so the rarity
    -- row is already full with the dropdown plus Unhide All.
    local searchLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", rarityLabel, "BOTTOMLEFT", 0, -22)
    searchLabel:SetText(L["Search:"])
    local search = CreateFrame("EditBox", "EbonClearanceLootSearch", win, "InputBoxTemplate")
    search:SetSize(190, 20)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetAutoFocus(false)
    -- v2.68.1: debounced via the shared helper - each keystroke used to
    -- re-run the full lootBuildArray sweep (GetItemInfo per item + sort;
    -- on Account scope that is the exact thousands-of-items pass the
    -- v2.68.0 rebuild was built to tame). The text stash stays immediate;
    -- only the rebuild waits for a 250 ms typing idle.
    NS.MakeSearchDebounce(search, function()
        lootRefresh(win)
    end, function(text)
        win.search = text
    end)
    search:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    -- Scroll chrome (matches the list windows' backdrop look).
    local scrollBg = CreateFrame("Frame", nil, win)
    -- v2.68.0: anchored to the last chrome row instead of the old fixed
    -- -120 offset. That magic number had to be hand-bumped every time a
    -- chrome row was added, and a missed bump overlaps the list on top of
    -- the row above it. Chaining it removes the trap.
    scrollBg:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -10)
    scrollBg:SetPoint("BOTTOMRIGHT", -12, 12)
    scrollBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    scrollBg:SetBackdropColor(0, 0, 0, 0.6)
    scrollBg:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)

    local scroll = CreateFrame("ScrollFrame", "EbonClearanceLootScroll", scrollBg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(290, 1)
    scroll:SetScrollChild(content)
    if NS.HookScrollbarAutoHide then
        NS.HookScrollbarAutoHide(scroll)
    end
    win.content = content
    -- v2.68.0: lootRenderVisible needs the viewport to know which slice of
    -- the array is on screen.
    win.scroll = scroll
    -- Re-bind the pooled rows as the view moves. HookScript, NOT SetScript:
    -- UIPanelScrollFrameTemplate's own OnVerticalScroll drives the
    -- scrollbar thumb, and replacing it would freeze the bar.
    scroll:HookScript("OnVerticalScroll", function()
        lootRenderVisible(win)
    end)

    -- Keep the scroll child's width in step with the (resizable) viewport so
    -- rows fill the window and never trigger a horizontal scrollbar. Rows
    -- anchor to content's TOPLEFT/TOPRIGHT, so they reflow automatically.
    scroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then
            content:SetWidth(w)
        end
        -- v2.68.0: a taller viewport needs more pooled rows bound, a
        -- shorter one needs the surplus hidden. Cheap - re-binds only the
        -- visible slice, no rebuild.
        lootRenderVisible(win)
    end)

    -- Bottom-right resize grip. Drag to resize; the row list grows/shrinks
    -- with the window. Standard Blizzard size-grabber textures.
    local grip = CreateFrame("Button", nil, win)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -5, 5)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        win:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        win:StopMovingOrSizing()
        lootRefresh(win)
    end)

    -- Live refresh while shown: loot accrues in the background, so a 1Hz
    -- tick keeps the open window current without a manual reopen. Cheap
    -- (one script call/sec, gated on visibility).
    win:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then
            return
        end
        self._lootTick = (self._lootTick or 0) + elapsed
        -- v2.50.1: rebuild when new loot was actually credited (EC_BumpLoot
        -- flips EC_compCache.lootWindowDirty), coalesced to at most once a
        -- second so a Scavenger multi-item burst rebuilds once. A 2 s safety
        -- refresh backs it up so the view can never go stale even if the
        -- flag is missed. Previously this rebuilt unconditionally every
        -- second - an open window kept calling GetItemInfo over every looted
        -- itemID and re-sorting even when nothing new had dropped (e.g. a
        -- boss fight with the window left open).
        -- v2.68.0: the unconditional safety refresh used to fire every 2 s
        -- forever. A rebuild walks every itemID in the scope calling
        -- GetItemInfo and re-sorts, so on Account scope (thousands of
        -- items) that was a full sweep twice a second-and-a-half, whether
        -- or not anything had changed. The dirty flag already catches real
        -- loot; the safety net only needs to be frequent while item names
        -- are still resolving from the cache primer. Once nothing is being
        -- primed it drops to a slow tick.
        local safetyEvery = (self._primedLast or 0) > 0 and 2.0 or 15.0
        if EC_compCache.lootWindowDirty and self._lootTick >= 1.0 then
            self._lootTick = 0
            EC_compCache.lootWindowDirty = false
            lootRefresh(self)
        elseif self._lootTick >= safetyEvery then
            self._lootTick = 0
            EC_compCache.lootWindowDirty = false
            lootRefresh(self)
        end
    end)

    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "EbonClearanceLootWindow")
    end

    lootWindow = win
    return win
end

local function ToggleLootWindow()
    local win = lootEnsureWindow()
    if win:IsShown() then
        win:Hide()
        return
    end
    lootRefresh(win)
    win:Show()
    if win.Raise then
        win:Raise()
    end
end
NS.ToggleLootWindow = ToggleLootWindow
