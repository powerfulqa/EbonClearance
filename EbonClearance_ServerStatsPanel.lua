-- EbonClearance_ServerStatsPanel - Stats - Server sub-panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- A realm-wide "collective odometer": anonymous combined totals from EC users
-- sharing right now (gold vendored, items sold/deleted/processed) + pooled top
-- zones/items + a live sharer count. NOT a leaderboard, NOT all-time - it's
-- whoever is online, opted in, and heard in the rolling window.
--
-- Rides NS.RealmComms (hidden-channel bus) + NS.ServerShare (aggregation).
-- Registered centrally in EbonClearance_Events.lua. Mirrors the Stats - Guild
-- panel's build/refresh/row patterns (fixed row pools + empty-state rows) so
-- the scroll layout stays stable.
--
-- Viewing requires "Share my totals" (reciprocity + it bounds the sample to
-- sharers). Sharing also puts you on the realm channel, so the existing
-- version-update alerts (Main panel) then hear new versions from the realm too.

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L

local ServerPanel = CreateFrame(
    "Frame",
    "EbonClearanceOptionsServer",
    InterfaceOptionsFramePanelContainer
)
ServerPanel.name = "Stats - Server"
ServerPanel.parent = "EbonClearance"

local VALUE_X = 220

local repaintServerPanel

local function makeRow(parent, anchor, yOff)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -2)
    row:SetHeight(14)
    EC_compCache.setPanelWidth(row, 16)
    row.left = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.left:SetJustifyH("LEFT")
    row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.right:SetPoint("LEFT", row, "LEFT", VALUE_X, 0)
    row.right:SetJustifyH("LEFT")
    return row
end

local function copperStr(c)
    return NS.CopperToColoredText and NS.CopperToColoredText(c or 0) or tostring(c or 0)
end

local function num(n)
    return NS.CommaNumber and NS.CommaNumber(n) or tostring(n or 0)
end

repaintServerPanel = function()
    local panel = ServerPanel
    if not panel._odoRows then
        return
    end
    if not (NS.ServerShare and NS.ServerShare.GetAggregate) then
        return
    end
    local agg = NS.ServerShare.GetAggregate()

    local odo = panel._odoRows
    odo.users.right:SetText(num(agg.userCount or 0))
    odo.gold.right:SetText(copperStr(agg.totalCopper))
    odo.sold.right:SetText(num(agg.itemsSold or 0))
    odo.deleted.right:SetText(num(agg.itemsDeleted or 0))
    odo.processed.right:SetText(num(agg.itemsProcessed or 0))

    -- Zone rows (agg.zones is already a sorted top-5 array).
    local zones = agg.zones or {}
    for i = 1, 5 do
        local row = panel._zoneRows[i]
        local e = zones[i]
        if e then
            row.left:SetText(e.name)
            row.right:SetText(copperStr(e.copper))
            row:Show()
        else
            row.left:SetText("")
            row.right:SetText("")
            row:Hide()
        end
    end
    if #zones > 0 then
        panel._zoneEmptyRow:Hide()
    else
        local hint = (EbonClearanceDB and EbonClearanceDB.shareServerData)
            and L["No zones shared yet."]
            or L["Turn on Share my totals to join the realm odometer."]
        panel._zoneEmptyRow.left:SetText(hint)
        panel._zoneEmptyRow.right:SetText("")
        panel._zoneEmptyRow:Show()
    end

    -- Item rows (agg.items is already a sorted top-5 array).
    local items = agg.items or {}
    for i = 1, 5 do
        local row = panel._itemRows[i]
        local e = items[i]
        if e then
            row.left:SetText(e.name or tostring(e.id))
            row.right:SetText("|cffffd100" .. num(e.count or 0) .. L["|r sold"])
            row.itemID = e.id
            row:Show()
        else
            row.left:SetText("")
            row.right:SetText("")
            row.itemID = nil
            row:Hide()
        end
    end
    if #items > 0 then
        panel._itemEmptyRow:Hide()
    else
        panel._itemEmptyRow.left:SetText(L["No items shared yet."])
        panel._itemEmptyRow.right:SetText("")
        panel._itemEmptyRow:Show()
    end
end

ServerPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(refreshSelf)
        repaintServerPanel()
    end, function(buildSelf, content)
        local heading = NS.MakeHeader(content, L["Stats - Server"], -16)
        if NS.AddHelpIcon then
            NS.AddHelpIcon(content, heading, "LEFT", "RIGHT", 8, 0, "server-stats")
        end

        local descLabel = NS.MakeLabel(
            content,
            L["A live, anonymous tally of what EbonClearance users across the realm"
                .. " have cleared together - totals only, never names or rankings."
                .. " Turn on Share my totals to join in and see it."],
            16,
            -44
        )

        local shareCB = NS.AddCheckbox(
            content,
            "EbonClearanceServerShareCB",
            descLabel,
            L["Share my totals with the realm (anonymous)"],
            function()
                return EbonClearanceDB and EbonClearanceDB.shareServerData
            end,
            function(v)
                if EbonClearanceDB then
                    EbonClearanceDB.shareServerData = v
                end
                if v and NS.RealmComms then
                    NS.RealmComms.Join()
                end
                if v and NS.ServerShare and NS.ServerShare.RequestNow then
                    NS.ServerShare.RequestNow()
                end
                repaintServerPanel()
            end,
            -10
        )

        -- ---- Realm Odometer ----
        local odoHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        odoHeader:SetPoint("TOPLEFT", shareCB, "BOTTOMLEFT", 0, -16)
        odoHeader:SetText(L["Realm Odometer"])

        local odo = {}
        local function makeOdoRow(leftText, anchor, yOff)
            local row = makeRow(content, anchor, yOff)
            row.left:SetText(leftText)
            row.right:SetText("")
            return row
        end
        odo.users = makeOdoRow(L["EC users sharing right now:"], odoHeader, -8)
        odo.gold = makeOdoRow(L["Combined gold vendored:"], odo.users, -2)
        odo.sold = makeOdoRow(L["Combined items sold:"], odo.gold, -2)
        odo.deleted = makeOdoRow(L["Combined items deleted:"], odo.sold, -2)
        odo.processed = makeOdoRow(L["Combined items processed:"], odo.deleted, -2)
        buildSelf._odoRows = odo

        -- ---- Realm's Best Farming Zones ----
        local zonesHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        zonesHeader:SetPoint("TOPLEFT", odo.processed, "BOTTOMLEFT", 0, -16)
        zonesHeader:SetText(L["Realm's Best Farming Zones"])

        buildSelf._zoneRows = {}
        local prevAnchor, prevYOff = zonesHeader, -8
        for i = 1, 5 do
            local row = makeRow(content, prevAnchor, prevYOff)
            row:Hide()
            buildSelf._zoneRows[i] = row
            prevAnchor, prevYOff = row, -2
        end
        local zoneEmptyRow = makeRow(content, zonesHeader, -8)
        zoneEmptyRow.left:SetText(L["No zones shared yet."])
        buildSelf._zoneEmptyRow = zoneEmptyRow

        -- ---- Realm's Most-Sold Items ----
        local itemsHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        itemsHeader:SetPoint("TOPLEFT", buildSelf._zoneRows[5], "BOTTOMLEFT", 0, -16)
        itemsHeader:SetText(L["Realm's Most-Sold Items"])

        buildSelf._itemRows = {}
        local iPrev, iYOff = itemsHeader, -8
        for i = 1, 5 do
            local row = makeRow(content, iPrev, iYOff)
            row.itemID = nil
            row:Hide()
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self2)
                if self2.itemID then
                    GameTooltip:SetOwner(self2, "ANCHOR_CURSOR")
                    GameTooltip:SetHyperlink("item:" .. self2.itemID)
                    GameTooltip:Show()
                end
            end)
            row:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            buildSelf._itemRows[i] = row
            iPrev, iYOff = row, -2
        end
        local itemEmptyRow = makeRow(content, itemsHeader, -8)
        itemEmptyRow.left:SetText(L["No items shared yet."])
        buildSelf._itemEmptyRow = itemEmptyRow

        local refreshBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        refreshBtn:SetSize(110, 24)
        refreshBtn:SetPoint("TOPLEFT", buildSelf._itemRows[5], "BOTTOMLEFT", 0, -12)
        refreshBtn:SetText(L["Refresh"])
        refreshBtn:SetScript("OnClick", function()
            if NS.ServerShare and NS.ServerShare.RequestNow then
                NS.ServerShare.RequestNow()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        repaintServerPanel()

        if NS.FitScrollContent then
            NS.FitScrollContent(content, refreshBtn)
        end
    end, true)

    if EbonClearanceDB and EbonClearanceDB.shareServerData and NS.ServerShare and NS.ServerShare.RequestNow then
        NS.ServerShare.RequestNow()
    end
    if NS.Delay then
        NS.Delay(10, function()
            if NS.RefreshServerStatsPanel then
                NS.RefreshServerStatsPanel()
            end
        end)
    end
end)

-- NS.RefreshServerStatsPanel: repaint if built. Called by the SDAT handler in
-- EbonClearance_ServerShare.lua as replies land.
NS.RefreshServerStatsPanel = function()
    local panel = _G["EbonClearanceOptionsServer"]
    if not panel or not panel.inited then
        return
    end
    repaintServerPanel()
end

-- Registration is handled centrally in EbonClearance_Events.lua.
