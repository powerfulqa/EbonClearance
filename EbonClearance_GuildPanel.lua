-- EbonClearance_GuildPanel - Stats - Guild sharing sub-panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Interface Options sub-panel for guild-share: opt-in toggle,
-- best farming zones aggregate, guild totals, quality breakdown,
-- most-sold items with hover tooltips, and a manual refresh button.
-- Registered centrally in EbonClearance_Events.lua (loads after this
-- file, so the frame exists when AddCategory is called).
--
-- Dependencies satisfied by NS:
--   * NS.compCache (Core)           - initPanel, setPanelWidth
--   * NS.MakeHeader / NS.MakeLabel  - panel text primitives
--   * NS.AddCheckbox                - opt-in toggle
--   * NS.FitScrollContent           - scroll height sizing
--   * NS.CopperToColoredText        - coloured gold strings
--   * NS.ColorTextByQuality         - rarity-coloured text
--   * NS.GuildShare                 - GetAggregate, RequestNow
--   * NS.Delay                      - deferred repaint after request

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L

local GuildPanel = CreateFrame(
    "Frame",
    "EbonClearanceOptionsGuild",
    InterfaceOptionsFramePanelContainer
)
GuildPanel.name = "Stats - Guild"
GuildPanel.parent = "EbonClearance"

-- x position at which the value column begins (pixels from row left edge).
local VALUE_X = 200

-- Rarity names indexed by quality constant (q = 0..7).
local QUALITY_NAMES = {
    [0] = L["Poor"],
    [1] = L["Common"],
    [2] = L["Uncommon"],
    [3] = L["Rare"],
    [4] = L["Epic"],
    [5] = L["Legendary"],
    [6] = L["Artifact"],
    [7] = L["Heirloom"],
}

-- repaintGuildPanel: shared repaint body used by both the OnShow
-- refresh callback and NS.RefreshGuildPanel. Forward-declared so the
-- OnShow closure and the NS exposure both capture the same upvalue.
local repaintGuildPanel

-- makeRow: build a two-column label+value row frame anchored below
-- `anchor`. The row frame is full-width (reactive) via setPanelWidth.
-- row.left  = left-justified label FontString.
-- row.right = value FontString whose left edge is at VALUE_X.
local function makeRow(parent, anchor, yOff)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -2)
    row:SetHeight(14)
    -- Full panel width so the frame is a reactive hover target.
    EC_compCache.setPanelWidth(row, 16)
    row.left = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.left:SetJustifyH("LEFT")
    row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.right:SetPoint("LEFT", row, "LEFT", VALUE_X, 0)
    row.right:SetJustifyH("LEFT")
    return row
end

repaintGuildPanel = function()
    local panel = GuildPanel
    -- Guard: row pools are built during the build pass; bail early if
    -- the panel has not been initialised yet.
    if not panel._zoneRows then
        return
    end
    if not (NS.GuildShare and NS.GuildShare.GetAggregate) then
        return
    end
    local agg = NS.GuildShare.GetAggregate()

    -- ---- Zone rows ----
    if agg.zones and next(agg.zones) then
        local entries = {}
        for name, z in pairs(agg.zones) do
            entries[#entries + 1] = {
                name = name,
                copper = z.copper or 0,
                contributors = z.contributors or 0,
            }
        end
        table.sort(entries, function(a, b)
            if a.copper == b.copper then
                return a.name < b.name
            end
            return a.copper > b.copper
        end)
        local limit = math.min(5, #entries)
        for i = 1, 5 do
            local row = panel._zoneRows[i]
            if i <= limit then
                local e = entries[i]
                local copperStr = NS.CopperToColoredText
                    and NS.CopperToColoredText(e.copper)
                    or tostring(e.copper)
                row.left:SetText(e.name)
                row.right:SetText(
                    copperStr .. L[" (from "] .. e.contributors .. ")"
                )
                row:Show()
            else
                row.left:SetText("")
                row.right:SetText("")
                row:Hide()
            end
        end
        -- Show the empty-state row only when there are real entries to
        -- hide (so it stays hidden when data is present).
        panel._zoneEmptyRow:Hide()
    else
        -- No data: hide all data rows, show the empty-state row.
        for i = 1, 5 do
            local row = panel._zoneRows[i]
            row.left:SetText("")
            row.right:SetText("")
            row:Hide()
        end
        panel._zoneEmptyRow.left:SetText(L["No zones shared yet."])
        panel._zoneEmptyRow.right:SetText("")
        panel._zoneEmptyRow:Show()
    end

    -- ---- Totals rows ----
    local totRows = panel._totalsRows
    if agg.memberCount and agg.memberCount > 0 then
        local copperStr = NS.CopperToColoredText
            and NS.CopperToColoredText(agg.totalCopper or 0)
            or tostring(agg.totalCopper or 0)
        local bestGPHStr = NS.CopperToColoredText
            and NS.CopperToColoredText(agg.bestGPH or 0)
            or tostring(agg.bestGPH or 0)
        if agg.bestGPHName then
            bestGPHStr = bestGPHStr .. " (" .. agg.bestGPHName .. ")"
        end

        -- Build the "Shared by" string.
        local named = {}
        for nm in pairs(agg.contributors or {}) do
            named[#named + 1] = nm
        end
        table.sort(named)
        local anon = (agg.memberCount or 0) - #named
        if anon < 0 then anon = 0 end
        local sharedByVal
        if #named > 0 then
            sharedByVal = table.concat(named, ", ")
            if anon > 0 then
                sharedByVal = sharedByVal .. " (+" .. anon .. L[" anonymous)"]
            end
        else
            sharedByVal = L["all anonymous"]
        end

        totRows.members.right:SetText(tostring(agg.memberCount or 0))
        totRows.gold.right:SetText(copperStr)
        totRows.items.right:SetText(tostring(agg.totalItems or 0))
        totRows.bestGPH.right:SetText(bestGPHStr)
        totRows.sharedBy.right:SetText(sharedByVal)

        -- Show all totals rows, hide the empty-state row.
        totRows.members:Show()
        totRows.gold:Show()
        totRows.items:Show()
        totRows.bestGPH:Show()
        totRows.sharedBy:Show()
        panel._totalsEmptyRow:Hide()
    else
        -- Empty state: hide data rows, show the hint.
        totRows.members:Hide()
        totRows.gold:Hide()
        totRows.items:Hide()
        totRows.bestGPH:Hide()
        totRows.sharedBy:Hide()
        panel._totalsEmptyRow.left:SetText(
            L["Open with guildmates online, or click Refresh."]
        )
        panel._totalsEmptyRow.right:SetText("")
        panel._totalsEmptyRow:Show()
    end

    -- ---- Quality breakdown ----
    if panel._qualityFS then
        local parts = {}
        for q = 0, 7 do
            local cnt = agg.quality and agg.quality[q]
            if cnt and cnt > 0 then
                local label = (QUALITY_NAMES[q] or tostring(q)) .. " " .. cnt
                local colored = NS.ColorTextByQuality
                    and NS.ColorTextByQuality(q, label)
                    or label
                parts[#parts + 1] = colored
            end
        end
        if #parts > 0 then
            panel._qualityFS:SetText(table.concat(parts, "  "))
        else
            panel._qualityFS:SetText(L["None shared yet."])
        end
    end

    -- ---- Item rows ----
    if agg.items and next(agg.items) then
        local entries = {}
        for id, e in pairs(agg.items) do
            entries[#entries + 1] = {
                id = id,
                name = e.name or tostring(id),
                count = e.count or 0,
                contributors = e.contributors or 0,
            }
        end
        table.sort(entries, function(a, b)
            if a.count == b.count then
                return a.name < b.name
            end
            return a.count > b.count
        end)
        local limit = math.min(5, #entries)
        for i = 1, 5 do
            local row = panel._itemRows[i]
            if i <= limit then
                local e = entries[i]
                row.left:SetText(e.name)
                row.right:SetText(
                    "|cffffd100" .. e.count .. L["|r sold (from "] .. e.contributors .. ")"
                )
                row.itemID = e.id
                row:Show()
            else
                row.left:SetText("")
                row.right:SetText("")
                row.itemID = nil
                row:Hide()
            end
        end
        panel._itemEmptyRow:Hide()
    else
        for i = 1, 5 do
            local row = panel._itemRows[i]
            row.left:SetText("")
            row.right:SetText("")
            row.itemID = nil
            row:Hide()
        end
        panel._itemEmptyRow.left:SetText(L["No items shared yet."])
        panel._itemEmptyRow.right:SetText("")
        panel._itemEmptyRow:Show()
    end
end

GuildPanel:SetScript("OnShow", function(self)
    -- Forward-declare so both the refresh closure and the build closure
    -- can capture syncNameEnabled as a shared upvalue.
    local nameCB
    local syncNameEnabled

    EC_compCache.initPanel(self, function(refreshSelf)
        -- Refresh pass: repaint data rows on subsequent OnShow.
        repaintGuildPanel()
        if syncNameEnabled then
            syncNameEnabled()
        end
    end, function(buildSelf, content)
        -- Build pass: runs once on the first OnShow.

        local heading = NS.MakeHeader(content, L["Stats - Guild"], -16)
        if NS.AddHelpIcon then
            NS.AddHelpIcon(content, heading, "LEFT", "RIGHT", 8, 0, "guild-sharing")
        end

        local descLabel = NS.MakeLabel(
            content,
            L["See what your guild is farming and selling, pooled from members"
                .. " who opt in. Guild and group only. Shared anonymously"
                .. " unless a member turns on Show my name."],
            16,
            -44
        )

        -- Opt-in checkbox. Reads/writes the top-level SavedVariables field
        -- directly (no DB proxy upvalue), matching the version-alert toggle
        -- on the Main panel.
        local optInCB = NS.AddCheckbox(
            content,
            "EbonClearanceGuildShareCB",
            descLabel,
            L["Share my farming data with my guild (anonymous)"],
            function()
                return EbonClearanceDB and EbonClearanceDB.shareGuildData
            end,
            function(v)
                if EbonClearanceDB then
                    EbonClearanceDB.shareGuildData = v
                end
                if syncNameEnabled then
                    syncNameEnabled()
                end
            end,
            -10
        )

        -- "Show my name" opt-in: appends this player's name to the
        -- contributors list visible to guildmates in the Totals block.
        -- Assigned to the forward-declared upvalue (not a new local) so
        -- syncNameEnabled can reference it.
        nameCB = NS.AddCheckbox(
            content,
            "EbonClearanceGuildNameCB",
            optInCB,
            L["Show my name with my shared data"],
            function() return EbonClearanceDB and EbonClearanceDB.shareGuildName end,
            function(v) if EbonClearanceDB then EbonClearanceDB.shareGuildName = v end end,
            -8
        )

        -- syncNameEnabled: mirrors the syncILvlSubsEnabled pattern in
        -- EbonClearance_ItemHighlightingPanel.lua. Enables/disables nameCB
        -- and tints its label to reflect whether sharing is active.
        syncNameEnabled = function()
            if not nameCB then
                return
            end
            local label = _G["EbonClearanceGuildNameCB" .. "Text"]
            if EbonClearanceDB and EbonClearanceDB.shareGuildData then
                nameCB:Enable()
                nameCB:SetChecked(EbonClearanceDB.shareGuildName)
                if label then
                    label:SetTextColor(1, 1, 1)
                end
            else
                nameCB:Disable()
                nameCB:SetChecked(false)
                if label then
                    label:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
        syncNameEnabled()

        -- ---- Guild's Best Farming Zones ----
        local zonesHeader = content:CreateFontString(
            nil, "ARTWORK", "GameFontNormalLarge"
        )
        zonesHeader:SetPoint("TOPLEFT", nameCB, "BOTTOMLEFT", 0, -16)
        zonesHeader:SetText(L["Guild's Best Farming Zones"])

        -- Pre-create a fixed pool of 5 zone rows + 1 empty-state row.
        -- The first row anchors under the sub-header; subsequent rows
        -- chain under the previous row.
        buildSelf._zoneRows = {}
        local prevAnchor = zonesHeader
        local prevYOff = -8
        for i = 1, 5 do
            local row = makeRow(content, prevAnchor, prevYOff)
            row.left:SetText("")
            row.right:SetText("")
            row:Hide()
            buildSelf._zoneRows[i] = row
            prevAnchor = row
            prevYOff = -2
        end
        -- Empty-state row (visible when no data).
        local zoneEmptyRow = makeRow(content, zonesHeader, -8)
        zoneEmptyRow.left:SetText(L["No zones shared yet."])
        zoneEmptyRow.right:SetText("")
        buildSelf._zoneEmptyRow = zoneEmptyRow

        -- ---- Guild Totals ----
        -- Anchor the header below whichever of the zone rows / empty row
        -- is the last one in the layout chain. Since the rows are shown
        -- and hidden dynamically we anchor from the LAST zone row (row 5)
        -- with a gap, which always reserves enough space. The last zone
        -- row holds position even when hidden; the empty row sits at the
        -- same y offset as row 1 so it shares the same vertical slot.
        local totalsHeader = content:CreateFontString(
            nil, "ARTWORK", "GameFontNormalLarge"
        )
        totalsHeader:SetPoint(
            "TOPLEFT", buildSelf._zoneRows[5], "BOTTOMLEFT", 0, -16
        )
        totalsHeader:SetText(L["Guild Totals"])

        -- Pre-create the fixed set of totals rows.
        local totRows = {}
        local function makeTotRow(leftText, anchor, yOff)
            local row = makeRow(content, anchor, yOff)
            row.left:SetText(leftText)
            row.right:SetText("")
            return row
        end

        totRows.members = makeTotRow(L["Members shared:"], totalsHeader, -8)
        totRows.gold    = makeTotRow(L["Combined gold:"], totRows.members, -2)
        totRows.items   = makeTotRow(L["Combined items sold:"], totRows.gold, -2)
        totRows.bestGPH = makeTotRow(L["Best gold/hour seen:"], totRows.items, -2)
        -- "Shared by" row: extra gap above so the first line clears the
        -- "Best gold/hour seen" row; doubled height so a two-line wrap
        -- has room; value anchored TOPLEFT so overflow grows downward.
        totRows.sharedBy = makeTotRow(L["Shared by:"], totRows.bestGPH, -10)
        totRows.sharedBy:SetHeight(28)
        totRows.sharedBy.right:ClearAllPoints()
        totRows.sharedBy.right:SetPoint("TOPLEFT", totRows.sharedBy, "TOPLEFT", VALUE_X, 0)
        -- The "Shared by" value can be long: give it a reactive width so
        -- it wraps instead of overflowing. VALUE_X + 16 is the x offset
        -- from the content frame's TOPLEFT to the right edge (content is
        -- inset 16 px from panel edge; setPanelWidth(fs, x) means the fs
        -- width = EC_PANEL_WIDTH - x).
        EC_compCache.setPanelWidth(totRows.sharedBy.right, VALUE_X + 16)
        if totRows.sharedBy.right.SetWordWrap then
            totRows.sharedBy.right:SetWordWrap(true)
        end

        buildSelf._totalsRows = totRows

        -- Empty-state row (visible when memberCount == 0).
        local totalsEmptyRow = makeRow(content, totalsHeader, -8)
        totalsEmptyRow.left:SetText(
            L["Open with guildmates online, or click Refresh."]
        )
        totalsEmptyRow.right:SetText("")
        buildSelf._totalsEmptyRow = totalsEmptyRow

        -- ---- Guild Sold by Quality ----
        local qualHeader = content:CreateFontString(
            nil, "ARTWORK", "GameFontNormalLarge"
        )
        qualHeader:SetPoint(
            "TOPLEFT", totRows.sharedBy, "BOTTOMLEFT", 0, -16
        )
        qualHeader:SetText(L["Guild Sold by Quality"])

        local qualityFS = content:CreateFontString(
            nil, "ARTWORK", "GameFontHighlight"
        )
        qualityFS:SetPoint("TOPLEFT", qualHeader, "BOTTOMLEFT", 0, -8)
        EC_compCache.setPanelWidth(qualityFS, 16)
        qualityFS:SetJustifyH("LEFT")
        qualityFS:SetJustifyV("TOP")
        if qualityFS.SetWordWrap then
            qualityFS:SetWordWrap(true)
        end
        qualityFS:SetText(L["None shared yet."])
        buildSelf._qualityFS = qualityFS

        -- ---- Guild's Most-Sold Items ----
        local itemsHeader = content:CreateFontString(
            nil, "ARTWORK", "GameFontNormalLarge"
        )
        itemsHeader:SetPoint(
            "TOPLEFT", qualityFS, "BOTTOMLEFT", 0, -16
        )
        itemsHeader:SetText(L["Guild's Most-Sold Items"])

        -- Pre-create a fixed pool of 5 item rows + 1 empty-state row.
        buildSelf._itemRows = {}
        local iPrev = itemsHeader
        local iYOff = -8
        for i = 1, 5 do
            local row = makeRow(content, iPrev, iYOff)
            row.left:SetText("")
            row.right:SetText("")
            row.itemID = nil
            row:Hide()
            -- Item hover tooltip - wired once at build time.
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
            iPrev = row
            iYOff = -2
        end
        -- Empty-state row (visible when no data).
        local itemEmptyRow = makeRow(content, itemsHeader, -8)
        itemEmptyRow.left:SetText(L["No items shared yet."])
        itemEmptyRow.right:SetText("")
        buildSelf._itemEmptyRow = itemEmptyRow

        -- Refresh button. Fires a broadcast request then plays the
        -- standard checkbox click sound.
        local refreshBtn = CreateFrame(
            "Button", nil, content, "UIPanelButtonTemplate"
        )
        refreshBtn:SetSize(110, 24)
        -- Anchor below the last item row (row 5 always holds position).
        refreshBtn:SetPoint(
            "TOPLEFT", buildSelf._itemRows[5], "BOTTOMLEFT", 0, -12
        )
        refreshBtn:SetText(L["Refresh"])
        refreshBtn:SetScript("OnClick", function()
            if NS.GuildShare and NS.GuildShare.RequestNow then
                NS.GuildShare.RequestNow()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        -- Populate whatever the aggregate already holds at build time
        -- (may have data from earlier in the session).
        repaintGuildPanel()

        -- Size the scroll content to fit the last widget.
        if NS.FitScrollContent then
            NS.FitScrollContent(content, refreshBtn)
        end
    end, true)

    -- On every show (first and subsequent), broadcast a request and
    -- schedule a repaint so replies have time to arrive before display.
    if NS.GuildShare and NS.GuildShare.RequestNow then
        NS.GuildShare.RequestNow()
    end
    if NS.Delay then
        NS.Delay(3, function()
            if NS.RefreshGuildPanel then
                NS.RefreshGuildPanel()
            end
        end)
    end
end)

-- NS.RefreshGuildPanel: repaint the panel if it has been built.
-- Called by the GDAT handler in EbonClearance_GuildShare.lua so
-- the displayed data updates live as replies land.
NS.RefreshGuildPanel = function()
    local panel = _G["EbonClearanceOptionsGuild"]
    if not panel or not panel.inited then
        return
    end
    repaintGuildPanel()
end

-- Registration is handled centrally in EbonClearance_Events.lua.
