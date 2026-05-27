-- EbonClearance_MainPanel - main "EbonClearance" Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ix-a of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The top-level "EbonClearance" panel - the entry point users hit
-- first when opening Interface Options. Hosts the welcome blurb,
-- session stats (gold made / items sold / items deleted / repair
-- spend), lifetime stats, slash command reference, and the master
-- "Enabled" toggle.
--
-- Moved into this file:
--   * local MainOptions = CreateFrame(...) frame creation
--   * BuildMainPanel function (~153 LOC; builds the panel body)
--   * The MainOptions OnShow handler which composes RefreshStats +
--     BuildMainPanel through EC_compCache.initPanel
--
-- The panel-infrastructure helpers (MakeHeader, MakeLabel,
-- AddCheckbox, AddSlider, EC_PANEL_WIDTH, EC_UpdatePanelWidth,
-- EC_compCache.initPanel, registerWidth, setPanelWidth, etc.) all
-- STAY in EbonClearance.lua for now; they're shared across every
-- panel and will move in a later stage.
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth
--   * NS.DB / NS.ADB captured at OnShow + BuildMainPanel entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.FitScrollContent (8e-ii)
--   * NS.CopperToColoredText (Stage 8 era)
--   * NS.GetVersion (Stage 8 era)
--   * NS.ResetSession (8e-ix-a prep) - session-stats reset handler
--     used by the Reset Session button on this panel

local NS = select(2, ...)
local EC_compCache = NS.compCache

local MainOptions = CreateFrame("Frame", "EbonClearanceOptionsMain", InterfaceOptionsFramePanelContainer)
MainOptions.name = "EbonClearance"

-- ---------------------------------------------------------------------------
-- NS.RefreshStats / NS.ResetLifetimeStats - namespace-exposed helpers.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-b of the file split: the stats refresh + lifetime-reset
-- logic was a closure local to MainOptions:OnShow. Stats widgets are
-- moving to EbonClearance_StatsPanel.lua (Task 4) and the data-change
-- handlers in EbonClearance_Events.lua need to drive a refresh without
-- knowing which panel owns the FontStrings. Hoisting these to file
-- scope and exposing them on NS gives callers a stable entry point.
-- The stats widgets now hang on _G["EbonClearanceOptionsStats"]; both
-- functions look it up and no-op if the panel isn't built yet.

local function GetMostItem(countTable)
    local bestID, bestCount = nil, 0
    if type(countTable) ~= "table" then
        return nil, 0
    end
    for id, cnt in pairs(countTable) do
        if type(id) == "number" and type(cnt) == "number" and cnt > bestCount then
            bestID, bestCount = id, cnt
        end
    end
    return bestID, bestCount
end

-- ItemLabel: resolve an itemID to a coloured name string, with a
-- cache-warmup deferred re-render for cold-cache cases. The warmup
-- flag hangs on the stats panel itself so a hidden panel doesn't
-- accumulate pending refreshes.
local function ItemLabel(id)
    if not id then
        return "None"
    end
    local name = GetItemInfo(id)
    if name then
        return string.format("|cff24ffb6%s|r", name)
    end
    -- GetItemInfo cold-cache. Post per-character partition (v2.34.0),
    -- each character inherits the snapshot of accumulated counts -
    -- which can include items the current character has never seen
    -- this session, and those items haven't been requested from the
    -- server yet. Trigger a SetHyperlink-driven cache fetch and
    -- schedule one re-render so the name resolves the moment the
    -- client receives the data (typically 100-300 ms). Falls back
    -- to the ItemID string for this paint; the re-render replaces it.
    if NS.scanTooltip and NS.scanTooltip.SetHyperlink then
        NS.scanTooltip:ClearLines()
        NS.scanTooltip:SetHyperlink("item:" .. tostring(id))
    end
    local statsPanel = _G["EbonClearanceOptionsStats"]
    if statsPanel and not statsPanel._statsWarmupPending and NS.Delay then
        statsPanel._statsWarmupPending = true
        NS.Delay(0.6, function()
            statsPanel._statsWarmupPending = nil
            if statsPanel.IsShown and statsPanel:IsShown() and NS.RefreshStats then
                NS.RefreshStats()
            end
        end)
    end
    return "ItemID: " .. tostring(id)
end

function NS.RefreshStats()
    local panel = _G["EbonClearanceOptionsStats"]
    if not panel or not panel.statsMoney then
        return
    end
    local DB = NS.DB
    if not DB then
        return
    end
    local function sessionSuffix(n)
        return string.format("  |cff888888(session +%s)|r", tostring(n or 0))
    end
    local function sessionMoneySuffix(c)
        return "  |cff888888(session +" .. NS.CopperToColoredText(c or 0) .. "|cff888888)|r"
    end
    panel.statsMoney:SetText(
        "Total Money Made: " .. NS.CopperToColoredText(DB.totalCopper or 0) .. sessionMoneySuffix(NS.session.copper)
    )
    panel.statsSold:SetText(
        "Total Items Sold: " .. tostring(DB.totalItemsSold or 0) .. sessionSuffix(NS.session.sold)
    )
    panel.statsDeleted:SetText(
        "Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0) .. sessionSuffix(NS.session.deleted)
    )
    panel.statsRepairs:SetText(
        "Total Repairs: " .. tostring(DB.totalRepairs or 0) .. sessionSuffix(NS.session.repairs)
    )
    panel.statsRepairCost:SetText(
        "Total Repair Cost: "
            .. NS.CopperToColoredText(DB.totalRepairCopper or 0)
            .. sessionMoneySuffix(NS.session.repairCopper)
    )

    -- v2.35.x: Session + Best Gold/Hour. See
    -- docs/specs/2026-05-26-gph-stats-design.md for the design.
    --
    -- The session line shows the live rate (copper/hour) computed
    -- from session.copper / elapsed-seconds, with a 10-second floor
    -- on the elapsed value so sub-second extrapolation doesn't
    -- produce absurd numbers in the moment right after /reload.
    -- The best line shows the per-character record + the zone +
    -- when context. Only updates the best when the session has
    -- run for at least 5 minutes (300s gate) - filters early-
    -- session burst noise.
    local startedAt = NS.session.startedAt or 0
    local now = GetTime()
    local elapsed = (startedAt > 0) and (now - startedAt) or 0
    local function humanDuration(secs)
        secs = math.floor(secs)
        if secs < 60 then
            return string.format("%ds", secs)
        elseif secs < 3600 then
            return string.format("%dm %ds", math.floor(secs / 60), secs % 60)
        end
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        local s = secs % 60
        return string.format("%dh %dm %ds", h, m, s)
    end
    local sessionGPH
    if elapsed >= 10 then
        sessionGPH = math.floor((NS.session.copper / elapsed) * 3600)
    end
    if panel.statsSessionGPH then
        if sessionGPH then
            panel.statsSessionGPH:SetText(
                "Session Gold/Hour: "
                    .. NS.CopperToColoredText(sessionGPH)
                    .. string.format("  |cff888888(%s)|r", humanDuration(elapsed))
            )
        else
            panel.statsSessionGPH:SetText(
                "Session Gold/Hour: |cff888888-  (computing...)|r"
            )
        end
    end

    -- Best-update gate: 5 minutes of session AND new high.
    if sessionGPH and elapsed >= 300 and sessionGPH > (DB.bestGPH or 0) then
        DB.bestGPH = sessionGPH
        DB.bestGPHAt = time()
        local zone = GetRealZoneText()
        DB.bestGPHZone = (zone and zone ~= "") and zone or "Unknown"
    end

    if panel.statsBestGPH then
        local best = DB.bestGPH or 0
        if best > 0 then
            local at = DB.bestGPHAt or 0
            local zone = DB.bestGPHZone
            if not zone or zone == "" then
                zone = "Unknown"
            end
            local when
            if at <= 0 then
                when = "unknown date"
            else
                local secs = time() - at
                if secs < 60 then
                    when = "just now"
                elseif secs < 3600 then
                    local n = math.floor(secs / 60)
                    when = string.format("%d minute%s ago", n, n == 1 and "" or "s")
                elseif secs < 86400 then
                    local n = math.floor(secs / 3600)
                    when = string.format("%d hour%s ago", n, n == 1 and "" or "s")
                elseif secs < 30 * 86400 then
                    local n = math.floor(secs / 86400)
                    when = string.format("%d day%s ago", n, n == 1 and "" or "s")
                else
                    when = date("%Y-%m-%d", at)
                end
            end
            panel.statsBestGPH:SetText(
                "Best Gold/Hour: "
                    .. NS.CopperToColoredText(best)
                    .. string.format("\n  |cff888888in %s, %s|r", zone, when)
            )
        else
            panel.statsBestGPH:SetText("Best Gold/Hour: |cff888888-|r")
        end
    end

    if panel.statsAvgWorth then
        local cnt = DB.inventoryWorthCount or 0
        local total = DB.inventoryWorthTotal or 0
        local avg = 0
        if cnt > 0 then
            avg = math.floor((total / cnt) + 0.5)
        end
        panel.statsAvgWorth:SetText("Average Inventory Worth: " .. NS.CopperToColoredText(avg))
    end

    if panel.statsMostSold then
        local mostID, mostCount = GetMostItem(DB.soldItemCounts)
        if mostID then
            panel.statsMostSold:SetText("Most Sold Item: " .. ItemLabel(mostID) .. " (x" .. tostring(mostCount) .. ")")
        else
            panel.statsMostSold:SetText("Most Sold Item: None")
        end
    end
end

function NS.ResetLifetimeStats()
    local DB = NS.DB
    if not DB then
        return
    end
    DB.totalCopper = 0
    DB.totalItemsSold = 0
    DB.totalItemsDeleted = 0
    DB.totalRepairs = 0
    DB.totalRepairCopper = 0
    DB.inventoryWorthTotal = 0
    DB.inventoryWorthCount = 0
    wipe(DB.soldItemCounts)
    wipe(DB.deletedItemCounts)
    -- v2.35.x: Reset Lifetime wipes the GPH best record too.
    -- The user is opting in to a full lifetime reset; per the
    -- spec (docs/specs/2026-05-26-gph-stats-design.md) the
    -- best record is part of lifetime state and goes with it.
    DB.bestGPH = 0
    DB.bestGPHAt = 0
    DB.bestGPHZone = ""
end


local function BuildMainPanel(panel, content)
    -- v2.12.0: widgets are created on `content` (the scroll-frame child)
    -- so vertical overflow is handled by the scroll bar. Stat refs are
    -- still stored on `panel` (the outer Interface Options panel) so
    -- RefreshStats's panel.statsX reads keep working across re-OnShows.
    -- The Reset buttons call NS.RefreshStats / NS.ResetLifetimeStats
    -- directly, so no refresh callback needs threading through this
    -- function any more.
    local addonVersion = NS.GetVersion()
    NS.MakeHeader(content, "EbonClearance " .. addonVersion, -16)

    -- Byline (required by LICENSE; do not remove in derivatives).
    local byline = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    byline:SetPoint("TOPLEFT", 16, -32)
    byline:SetText("|cff888866by " .. NS.ADDON_AUTHOR .. "  \194\183  " .. NS.ADDON_URL .. "|r")

    local welcomeLabel = NS.MakeLabel(
        content,
        "Welcome to |cffb6ffb6EbonClearance|r - bag management for Project Ebonhold.",
        16,
        -52
    )
    local descLabel2 = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    descLabel2:SetPoint("TOPLEFT", welcomeLabel, "BOTTOMLEFT", 0, -4)
    EC_compCache.setPanelWidth(descLabel2, 16)
    descLabel2:SetJustifyH("LEFT")
    descLabel2:SetJustifyV("TOP")
    if descLabel2.SetWordWrap then
        descLabel2:SetWordWrap(true)
    end
    descLabel2:SetText(
        "Out of the box it sells your junk and old gear when you visit a merchant, keeps your upgrades, and never touches anything important.\n\n"
            .. "Want more control?\n"
            .. "  |cffb6ffb6Sell List|r - items you want sold every time.\n"
            .. "  |cffb6ffb6Keep List|r - items the addon should never touch.\n"
            .. "  |cffb6ffb6Merchant Settings|r - change what counts as old gear.\n"
            .. "  |cffb6ffb6Process Bags|r - one button to disenchant, mill, prospect, or pick locks."
    )
    -- Tip on its own line, in grey, so it reads as a hint rather than
    -- another sentence in the main description block.
    local mainTip = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    mainTip:SetPoint("TOPLEFT", descLabel2, "BOTTOMLEFT", 0, -10)
    EC_compCache.setPanelWidth(mainTip, 16)
    mainTip:SetJustifyH("LEFT")
    mainTip:SetJustifyV("TOP")
    if mainTip.SetWordWrap then
        mainTip:SetWordWrap(true)
    end
    mainTip:SetText("|cff888888Right-click any bag item with Alt held for quick actions.|r")

    -- Stats fontstrings. Stacked vertically; each attaches its ref to `panel`
    -- so RefreshStats can find them across subsequent OnShow calls.
    local money = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    money:SetPoint("TOPLEFT", mainTip, "BOTTOMLEFT", 0, -16)
    panel.statsMoney = money

    local sold = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sold:SetPoint("TOPLEFT", money, "BOTTOMLEFT", 0, -6)
    panel.statsSold = sold

    local deleted = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    deleted:SetPoint("TOPLEFT", sold, "BOTTOMLEFT", 0, -6)
    panel.statsDeleted = deleted

    local repairs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairs:SetPoint("TOPLEFT", deleted, "BOTTOMLEFT", 0, -6)
    panel.statsRepairs = repairs

    local repairCost = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairCost:SetPoint("TOPLEFT", repairs, "BOTTOMLEFT", 0, -6)
    panel.statsRepairCost = repairCost

    -- v2.35.x: Session and Best Gold/Hour. The session line shows the
    -- live rate plus elapsed time; the best line shows the per-character
    -- record with the zone + when context on its own indented sub-line.
    -- See docs/specs/2026-05-26-gph-stats-design.md for the data shape +
    -- 5-minute gate rationale.
    local sessionGPH = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sessionGPH:SetPoint("TOPLEFT", repairCost, "BOTTOMLEFT", 0, -6)
    panel.statsSessionGPH = sessionGPH

    local bestGPH = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    bestGPH:SetPoint("TOPLEFT", sessionGPH, "BOTTOMLEFT", 0, -6)
    EC_compCache.setPanelWidth(bestGPH, 16)
    bestGPH:SetJustifyH("LEFT")
    panel.statsBestGPH = bestGPH

    local avgWorth = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    avgWorth:SetPoint("TOPLEFT", bestGPH, "BOTTOMLEFT", 0, -6)
    panel.statsAvgWorth = avgWorth

    local mostSold = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    mostSold:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -6)
    EC_compCache.setPanelWidth(mostSold, 16)
    mostSold:SetJustifyH("LEFT")
    panel.statsMostSold = mostSold

    local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statsNote:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -4)
    EC_compCache.setPanelWidth(statsNote, 16)
    statsNote:SetJustifyH("LEFT")
    statsNote:SetText("|cff888888Stats don't account for items bought back from a merchant.|r")

    local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", content, "UIPanelButtonTemplate")
    resetBtn:SetSize(170, 22)
    resetBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -8)
    resetBtn:SetText("Reset Lifetime Stats")
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
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    -- Session delta is inlined into each lifetime stat line by RefreshStats (NS.session).
    -- The Reset Session button sits side-by-side with Reset Lifetime to avoid adding vertical space.
    local resetSessionBtn = CreateFrame("Button", "EbonClearanceResetSessionBtn", content, "UIPanelButtonTemplate")
    resetSessionBtn:SetSize(170, 22)
    resetSessionBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
    resetSessionBtn:SetText("Reset Session Stats")
    resetSessionBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("EC_CONFIRM_RESET_SESSION")
        if dialog then
            dialog.data = function()
                NS.ResetSession()
                if NS.RefreshStats then
                    NS.RefreshStats()
                end
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    -- Slash commands reference.
    local cmdHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cmdHeader:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -16)
    cmdHeader:SetText("Slash Commands")

    local cmdText = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cmdText:SetPoint("TOPLEFT", cmdHeader, "BOTTOMLEFT", 0, -6)
    EC_compCache.setPanelWidth(cmdText, 16)
    cmdText:SetJustifyH("LEFT")
    if cmdText.SetWordWrap then
        cmdText:SetWordWrap(true)
    end
    cmdText:SetText(
        "|cffffff00/ec|r  Open settings\n"
            .. "|cffffff00/ec profile [list|save|load|delete <name>]|r  Save and load setting profiles\n"
            .. "|cffffff00/ec clean [apply]|r  Find items on more than one list and fix them\n"
            .. "|cffffff00/ec clean upgrades [apply]|r  Remove old 'Upgrade'-tagged items from Keep List\n"
            .. "|cffffff00/ec sellinfo [bag slot]|r  Explain why an item will or won't sell |cffaaaaaa(or Alt+Shift+Right-Click)|r\n"
            .. "|cffffff00/ec bugreport|r  Generate a report to share when something's wrong\n"
            .. "|cffffff00/ec help|r  Show all commands in chat"
    )

    -- v2.12.0: size the scroll content to fit the bottom-most widget so
    -- the scroll bar engages when the Interface Options frame is too
    -- short to show everything (matches the Scavenger / Merchant /
    -- Profiles / Import-Export panels' pattern).
    NS.FitScrollContent(content, cmdText)
end

MainOptions:SetScript("OnShow", function(self)
    -- RefreshStats / ResetLifetimeStats now live on NS at file scope
    -- (see top of this file). The OnShow just composes BuildMainPanel +
    -- a refresh through EC_compCache.initPanel; the Reset buttons inside
    -- BuildMainPanel call NS.RefreshStats / NS.ResetLifetimeStats directly.
    EC_compCache.initPanel(self, function()
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, function(buildSelf, content)
        -- v2.12.0: scroll-wrap the Main panel so the Slash Commands block
        -- at the bottom doesn't overlap the OK/Cancel button strip when
        -- the Interface Options frame is shorter than the panel content.
        -- Scavenger and Merchant Settings are wrapped the same way.
        BuildMainPanel(buildSelf, content)
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, true)
end)
