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
        if self:IsShown() and NS.RefreshStats then
            NS.RefreshStats()
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

        -- Lifetime + session stats. Each panel.statsX is the contract
        -- with RefreshStats (called from EbonClearance_Events.lua's data
        -- handlers). Order matches the old MainPanel layout for visual
        -- continuity. The explicit panel.statsX = fs assignments below
        -- are the contract the test suite scans for - keep them literal
        -- (no table-driven indirection) so the static-pattern check can
        -- find them.
        local function makeStatRow(yOffset, anchorPrev)
            local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            fs:SetPoint("TOPLEFT", anchorPrev, "BOTTOMLEFT", 0, yOffset)
            EC_compCache.setPanelWidth(fs, 16)
            fs:SetJustifyH("LEFT")
            return fs
        end

        -- v2.38.1: first stat row anchors below the started-at note now
        -- (was -44 from content TOPLEFT, which assumed the heading was
        -- the only thing above the stats).
        local money = makeStatRow(-16, startedAtNote)
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
        -- v2.37.0: Sold-by-Quality breakdown. Multi-line FontString; the
        -- row height grows with the number of quality buckets that have
        -- nonzero counts (RefreshStats emits 1-8 indented rows). Width
        -- is registered via setPanelWidth so live panel-resize keeps
        -- the text flush. Word-wrap is set TRUE explicitly (the same
        -- guard every other panel uses for multi-line content) so a long
        -- row wraps instead of truncating; the \n breaks RefreshStats
        -- emits render as separate lines either way.
        local qualityBreakdown = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        qualityBreakdown:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(qualityBreakdown, 16)
        qualityBreakdown:SetJustifyH("LEFT")
        qualityBreakdown:SetJustifyV("TOP")
        if qualityBreakdown.SetWordWrap then
            qualityBreakdown:SetWordWrap(true)
        end
        panel.statsQualityBreakdown = qualityBreakdown
        -- v2.37.x: "Deleted by Quality" mirrors "Sold by Quality" -
        -- per-rarity counts only (no copper, deletion produces no
        -- money). Rendered when DB.deletedItemsByQuality has any
        -- non-zero entry; reads "None yet" otherwise.
        local deletedByQuality = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        deletedByQuality:SetPoint("TOPLEFT", qualityBreakdown, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(deletedByQuality, 16)
        deletedByQuality:SetJustifyH("LEFT")
        deletedByQuality:SetJustifyV("TOP")
        if deletedByQuality.SetWordWrap then
            deletedByQuality:SetWordWrap(true)
        end
        panel.statsDeletedByQuality = deletedByQuality
        -- v2.37.0: panel.statsMostSold is now a multi-line "Top 5 Most
        -- Sold" widget. The name is preserved because Test 80 docs
        -- reference it as a contract surface; the format changed from
        -- single-line "Most Sold Item: ..." to a heading + up to five
        -- ranked rows. RefreshStats writes the full block via
        -- table.concat with "\n" so it grows row by row.
        local mostSold = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        mostSold:SetPoint("TOPLEFT", deletedByQuality, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(mostSold, 16)
        mostSold:SetJustifyH("LEFT")
        mostSold:SetJustifyV("TOP")
        if mostSold.SetWordWrap then
            mostSold:SetWordWrap(true)
        end
        panel.statsMostSold = mostSold
        -- v2.37.x: Top 5 Most Deleted mirrors Top 5 Most Sold.
        -- Reuses GetTopNItems over DB.deletedItemCounts.
        local mostDeleted = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        mostDeleted:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(mostDeleted, 16)
        mostDeleted:SetJustifyH("LEFT")
        mostDeleted:SetJustifyV("TOP")
        if mostDeleted.SetWordWrap then
            mostDeleted:SetWordWrap(true)
        end
        panel.statsMostDeleted = mostDeleted

        -- v2.37.0: Process Bags lifetime totals (Disenchant / Mill /
        -- Prospect / Pick Lock). Multi-line; RefreshStats emits a
        -- header plus one row per nonzero counter.
        local processTotals = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        processTotals:SetPoint("TOPLEFT", mostDeleted, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(processTotals, 16)
        processTotals:SetJustifyH("LEFT")
        processTotals:SetJustifyV("TOP")
        if processTotals.SetWordWrap then
            processTotals:SetWordWrap(true)
        end
        panel.statsProcessTotals = processTotals

        -- v2.37.0: Top zones by lifetime gold earned. RefreshStats emits
        -- a header plus up to five ranked zone rows (gold-desc) so the
        -- player can see where they've grossed the most.
        local topZones = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        topZones:SetPoint("TOPLEFT", processTotals, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(topZones, 16)
        topZones:SetJustifyH("LEFT")
        topZones:SetJustifyV("TOP")
        if topZones.SetWordWrap then
            topZones:SetWordWrap(true)
        end
        panel.statsTopZones = topZones

        -- Footnote about buyback exclusion.
        local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        statsNote:SetPoint("TOPLEFT", topZones, "BOTTOMLEFT", 0, -4)
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
        -- Interface Options container's natural height. resetBtn is
        -- the last widget; FitScrollContent measures its bottom edge
        -- against the content frame's TOPLEFT. Same pattern as the
        -- Main / Scavenger / Merchant / Item Highlighting panels.
        if NS.FitScrollContent then
            NS.FitScrollContent(content, resetBtn)
        end
    end, true)
end)

-- v2.36.x: registered with InterfaceOptions_AddCategory from
-- EbonClearance_Events.lua (right after the Main panel) so the sub-panel
-- sort order (Main / Stats / Merchant / ...) is controlled at one place.
