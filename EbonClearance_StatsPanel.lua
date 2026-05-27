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

local StatsPanel = CreateFrame("Frame", "EbonClearanceOptionsStats", InterfaceOptionsFramePanelContainer)
StatsPanel.name = "Stats"
StatsPanel.parent = "EbonClearance"

StatsPanel:SetScript("OnShow", function(panel)
    EC_compCache.initPanel(panel, function(self)
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, function(self, content)
        -- Heading. Same -16 y offset as Keep List / Sell List etc.
        NS.MakeHeader(content, "Stats", -16)

        -- Lifetime + session stats. Each panel.statsX is the contract
        -- with RefreshStats (called from EbonClearance_Events.lua's data
        -- handlers). Order matches the old MainPanel layout for visual
        -- continuity. The explicit panel.statsX = fs assignments below
        -- are the contract the test suite scans for - keep them literal
        -- (no table-driven indirection) so the static-pattern check can
        -- find them.
        local function makeStatRow(yOffset, anchorPrev)
            local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            if anchorPrev == content then
                fs:SetPoint("TOPLEFT", content, "TOPLEFT", 16, yOffset)
            else
                fs:SetPoint("TOPLEFT", anchorPrev, "BOTTOMLEFT", 0, yOffset)
            end
            EC_compCache.setPanelWidth(fs, 16)
            fs:SetJustifyH("LEFT")
            return fs
        end

        local money = makeStatRow(-44, content)
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
        local mostSold = makeStatRow(-6, avgWorth)
        panel.statsMostSold = mostSold

        -- Footnote about buyback exclusion.
        local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        statsNote:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -4)
        EC_compCache.setPanelWidth(statsNote, 16)
        statsNote:SetJustifyH("LEFT")
        statsNote:SetText("|cff888888Stats don't account for items bought back from a merchant.|r")
        panel.statsNote = statsNote

        -- Reset Lifetime button (same global name + behaviour as before).
        local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", content, "UIPanelButtonTemplate")
        resetBtn:SetSize(170, 22)
        resetBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -10)
        resetBtn:SetText("Reset Lifetime Stats")
        resetBtn:SetScript("OnClick", function()
            if NS.ResetLifetimeStats then
                NS.ResetLifetimeStats()
            end
            if NS.RefreshStats then
                NS.RefreshStats()
            end
        end)

        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end)
end)

InterfaceOptions_AddCategory(_G["EbonClearanceOptionsStats"])
