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
-- button and by /ec loot. Read-only scroll list of items looted, count
-- only, in two scopes: Session (NS.lootSession, in-memory, clears on
-- /reload or Reset Session) and Account (the persisted account-wide
-- running total). Fixed-size window, so it never snapshots EC_PANEL_WIDTH
-- and is outside the reactive-width contract that governs the Interface
-- Options sub-panels. Loot capture + storage live in EbonClearance_Events.lua.
local lootWindow

local LOOT_ROW_H = 18
local LOOT_DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Forward-declared so the row factory's right-click handler (defined before
-- the body below) can call it as an upvalue. Assigned with `function
-- lootRefresh(win)` further down, NOT `local function`, so it stays the same
-- upvalue everything here captures.
local lootRefresh

-- Build a sorted array of { id, qty, value, name, quality, texture } for the
-- given scope (filtered by rarityFilter when set), plus the grand totals of
-- quantity AND vendor value across EVERY entry (so shares read as "of
-- everything looted", even with a rarity filter on). value = per-unit vendor
-- sell price (GetItemInfo) x quantity; it's 0 for items with no sell price,
-- which is itself useful - it flags the worthless drops worth deleting.
-- One GetItemInfo per item (cached) feeds both the sort and the render.
local function lootBuildArray(scope, sortKey, sortDir, rarityFilter)
    local src
    if scope == "account" then
        local AS = NS.ADB and NS.ADB.accountStats
        src = AS and AS.lootedItemCounts
    elseif scope == "character" then
        src = NS.DB and NS.DB.lootedItemCounts
    else
        src = NS.lootSession
    end
    -- Hidden items (right-clicked to hide) are dropped BEFORE the totals so
    -- the remaining rows' count/gold shares rebase as if the hidden ones were
    -- never looted. This differs from the rarity filter, which hides rows but
    -- keeps them in the totals.
    local hidden = (NS.ADB and NS.ADB.lootLogHidden) or {}
    local arr, total, totalValue = {}, 0, 0
    if src then
        for itemID, qty in pairs(src) do
            if qty and qty > 0 and not hidden[itemID] then
                local name, _, q, _, _, _, _, _, _, texture, sellPrice = GetItemInfo(itemID)
                local value = (sellPrice or 0) * qty
                total = total + qty
                totalValue = totalValue + value
                if rarityFilter == nil or q == rarityFilter then
                    arr[#arr + 1] = {
                        id = itemID,
                        qty = qty,
                        value = value,
                        name = name or ("item:" .. itemID),
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
    return arr, total, totalValue
end

-- Pooled row factory. Rows anchor to content's TOPLEFT/TOPRIGHT so they
-- stretch with the (fixed) content width; reused across Refresh calls.
local function lootGetRow(win, i)
    win.rows = win.rows or {}
    local row = win.rows[i]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, win.content)
    row:SetHeight(LOOT_ROW_H)
    row:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, -(i - 1) * LOOT_ROW_H)
    row:SetPoint("TOPRIGHT", win.content, "TOPRIGHT", 0, -(i - 1) * LOOT_ROW_H)
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

function lootRefresh(win)
    if not win then
        return
    end
    local arr, total, totalValue = lootBuildArray(win.scope or "session", win.sortKey, win.sortDir, win.rarityFilter)
    for i = 1, #arr do
        local e = arr[i]
        local row = lootGetRow(win, i)
        row.itemID = e.id
        local hex = "ffffffff"
        if e.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.quality] and ITEM_QUALITY_COLORS[e.quality].hex then
            hex = ITEM_QUALITY_COLORS[e.quality].hex:gsub("|c", "")
        end
        row.icon:SetTexture(e.texture or LOOT_DEFAULT_ICON)
        row.label:SetText(string.format("|c%s%s|r", hex, e.name))
        -- Amount column: count, vendor value, and that value's share of the
        -- FULL looted gold (grand total), so the % reads as "how much of my
        -- income is this drop" even with a rarity filter on. A worthless
        -- drop shows a grey dash + 0%, which is the cue to filter/delete it.
        local goldPct = (totalValue > 0) and (e.value / totalValue * 100) or 0
        local coin = (e.value > 0 and GetCoinTextureString) and GetCoinTextureString(e.value) or "|cff707070-|r"
        row.amount:SetText(string.format("|cff808080x%d|r  %s  |cff888888%.1f%%|r", e.qty, coin, goldPct))
        row:Show()
    end
    if win.rows then
        for i = #arr + 1, #win.rows do
            win.rows[i]:Hide()
        end
    end
    win.content:SetHeight(math.max(1, #arr * LOOT_ROW_H))
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
            local coinTotal = (totalValue > 0 and GetCoinTextureString) and GetCoinTextureString(totalValue) or "0"
            win.totalLine:SetText(string.format(L["%d items  |  %d looted  |  %s"], #arr, total, coinTotal))
        end
    end
end

local function lootEnsureWindow()
    if lootWindow then
        return lootWindow
    end
    local win = CreateFrame("Frame", "EbonClearanceLootWindow", UIParent)
    win:SetFrameStrata("FULLSCREEN_DIALOG")
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
    -- which rows show. Percentages stay relative to the FULL looted volume
    -- (the grand total computed in lootBuildArray), so a filtered view still
    -- reads as "share of everything looted" - the point of the percentage.
    -- Quality names come from the client's ITEM_QUALITYn_DESC globals so they
    -- are locale-correct without hand-written strings.
    local rarityLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rarityLabel:SetPoint("TOPLEFT", sortLabel, "BOTTOMLEFT", 0, -14)
    rarityLabel:SetText(L["Show:"])
    local RARITY_OPTS = {
        { text = L["All rarities"], q = nil },
        { text = _G["ITEM_QUALITY0_DESC"] or "Poor", q = 0 },
        { text = _G["ITEM_QUALITY1_DESC"] or "Common", q = 1 },
        { text = _G["ITEM_QUALITY2_DESC"] or "Uncommon", q = 2 },
        { text = _G["ITEM_QUALITY3_DESC"] or "Rare", q = 3 },
        { text = _G["ITEM_QUALITY4_DESC"] or "Epic", q = 4 },
    }
    local rarityDD = CreateFrame("Frame", "EbonClearanceLootRarityDD", win, "UIDropDownMenuTemplate")
    rarityDD:SetPoint("LEFT", rarityLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(rarityDD, 100)
    UIDropDownMenu_Initialize(rarityDD, function(_, level)
        for _, opt in ipairs(RARITY_OPTS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.text
            info.checked = (win.rarityFilter == opt.q)
            info.func = function()
                win.rarityFilter = opt.q
                UIDropDownMenu_SetText(rarityDD, opt.text)
                lootRefresh(win)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetText(rarityDD, L["All rarities"])

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

    -- Scroll chrome (matches the list windows' backdrop look).
    local scrollBg = CreateFrame("Frame", nil, win)
    scrollBg:SetPoint("TOPLEFT", 12, -120)
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

    -- Keep the scroll child's width in step with the (resizable) viewport so
    -- rows fill the window and never trigger a horizontal scrollbar. Rows
    -- anchor to content's TOPLEFT/TOPRIGHT, so they reflow automatically.
    scroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then
            content:SetWidth(w)
        end
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
        self._lootTick = (self._lootTick or 0) + elapsed
        if self._lootTick >= 1.0 then
            self._lootTick = 0
            if self:IsShown() then
                lootRefresh(self)
            end
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
